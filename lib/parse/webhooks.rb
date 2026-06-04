# encoding: UTF-8
# frozen_string_literal: true

require "active_model"
require "active_support"
require "active_support/inflector"
require "active_support/core_ext/object"
require "active_support/core_ext"
require "active_support/security_utils"
require "active_model/serializers/json"
require "rack"
require "ostruct"
require_relative "client"
# Note: Do not require "stack" here - this file is loaded from stack.rb
# and adding that require would create a circular dependency.
require_relative "model/object"
require_relative "webhooks/payload"
require_relative "webhooks/registration"
require_relative "webhooks/replay_protection"

module Parse
  class Object

    # Register a webhook function for this subclass.
    # @example
    #  class Post < Parse::Object
    #
    #   webhook_function :helloWorld do
    #      # ... do something when this function is called ...
    #   end
    #  end
    # @param functionName [String] the literal name of the function to be registered with the server.
    # @yield (see Parse::Object.webhook)
    # @param block (see Parse::Object.webhook)
    # @return (see Parse::Object.webhook)
    def self.webhook_function(functionName, &block)
      if block_given?
        Parse::Webhooks.route(:function, functionName, &block)
      else
        block = functionName.to_s.underscore.to_sym if block.blank?
        block = method(block.to_sym) if block.is_a?(Symbol)
        Parse::Webhooks.route(:function, functionName, block)
      end
    end

    # Register a webhook trigger or function for this subclass.
    # @example
    #  class Post < Parse::Object
    #
    #   webhook :before_save do
    #      # ... do something ...
    #     parse_object
    #   end
    #
    #  end
    # @param type (see Parse::Webhooks.route)
    # @yield the body of the function to be evaluated in the scope of a {Parse::Webhooks::Payload} instance.
    # @param block [Symbol] the name of the method to call, if no block is passed.
    # @return (see Parse::Webhooks.route)
    def self.webhook(type, &block)
      if type == :function
        unless block.is_a?(String) || block.is_a?(Symbol)
          raise ArgumentError, "Invalid Cloud Code function name: #{block}"
        end
        Parse::Webhooks.route(:function, block, &block)
        # then block must be a symbol or a string
      else
        if block_given?
          Parse::Webhooks.route(type, self, &block)
        else
          Parse::Webhooks.route(type, self, block)
        end
      end
      #if block

    end
  end

  # A Rack-based application middlware to handle incoming Parse cloud code webhook
  # requests.
  class Webhooks
    # The error to be raised in registered trigger or function webhook blocks that
    # will trigger the Parse::Webhooks application to return the proper error response.
    class ResponseError < StandardError; end

    include Client::Connectable
    extend Parse::Webhooks::Registration
    # The name of the incoming env containing the webhook key.
    HTTP_PARSE_WEBHOOK = "HTTP_X_PARSE_WEBHOOK_KEY"
    # The name of the incoming env containing the application id key.
    HTTP_PARSE_APPLICATION_ID = "HTTP_X_PARSE_APPLICATION_ID"
    # The content type that needs to be sent back to Parse server.
    CONTENT_TYPE = "application/json"

    # The Parse Webhook Key to be used for authenticating webhook requests.
    # See {Parse::Webhooks.key} on setting this value.
    # @return [String]
    def key
      self.class.key
    end

    class << self

      # Allows support for web frameworks that support auto-reloading of source.
      # @!visibility private
      def reload!(args = {})
      end

      # @return [Boolean] whether to print additional logging information. You may also
      #  set this to `:debug` for additional verbosity.
      attr_accessor :logging

      # A hash-like structure composing of all the registered webhook
      # triggers and functions. These are `:before_save`, `:after_save`,
      # `:before_delete`, `:after_delete` or `:function`.
      # @return [OpenStruct]
      def routes
        return @routes unless @routes.nil?
        r = Parse::API::Hooks::TRIGGER_NAMES_LOCAL + [:function]
        @routes = OpenStruct.new(r.reduce({}) { |h, t| h[t] = {}; h })
      end

      # Internally registers a route for a specific webhook trigger or function.
      # @param type [Symbol] The type of cloud code webhook to register. This can be any
      #  of the supported routes. These are `:before_save`, `:after_save`,
      # `:before_delete`, `:after_delete` or `:function`.
      # @param className [String] if `type` is not `:function`, then this registers
      #  a trigger for the given className. Otherwise, className is treated to be the function
      #  name to register with Parse server.
      # @yield the block that will handle of the webhook trigger or function.
      # @return (see routes)
      def route(type, className, &block)
        type = type.to_s.underscore.to_sym #support camelcase
        if type != :function && className.respond_to?(:parse_class)
          className = className.parse_class
        end
        className = className.to_s
        if routes[type].nil? || block.respond_to?(:call) == false
          raise ArgumentError, "Invalid Webhook registration trigger #{type} #{className}"
        end

        # AfterSave/AfterDelete hooks support more than one
        if type == :after_save || type == :after_delete
          routes[type][className] ||= []
          routes[type][className].push block
        else
          routes[type][className] = block
        end
        @routes
      end

      # Run a locally registered webhook function. This bypasses calling a
      # function through Parse-Server if the method handler is registered locally.
      # @return [Object] the result of the function.
      def run_function(name, params)
        payload = Payload.new
        payload.function_name = name
        payload.params = params
        call_route(:function, name, payload)
      end

      # Calls the set of registered webhook trigger blocks or the specific function block.
      # This method is usually called when an incoming request from Parse Server is received.
      # @param type (see route)
      # @param className (see route)
      # @param payload [Parse::Webhooks::Payload] the payload object received from the server.
      # @return [Object] the result of the trigger or function.
      def call_route(type, className, payload = nil)
        type = type.to_s.underscore.to_sym #support camelcase
        className = className.parse_class if className.respond_to?(:parse_class)
        className = className.to_s

        return unless routes[type].present? && routes[type][className].present?
        registry = routes[type][className]

        # Track the header-derived ruby_initiated flag on the payload so
        # user code can introspect it (`payload.ruby_initiated?`). For the
        # framework's own callback-deduplication logic below we use the
        # stricter `trusted_ruby_initiated`, which additionally requires the
        # master key. The X-Parse-Request-Id header is client-controllable,
        # so honoring `_RB_` alone would let any client send `_RB_attacker`
        # and trick the framework into skipping server-side callbacks.
        # Server-side Parse-Stack saves use the master key by default, so
        # the AND is a safe condition for legitimate Ruby-initiated traffic.
        if payload
          request_id = payload&.raw&.dig(:headers, "x-parse-request-id") ||
                       payload&.raw&.dig("headers", "x-parse-request-id") ||
                       payload&.raw&.dig(:headers, "X-Parse-Request-Id") ||
                       payload&.raw&.dig("headers", "X-Parse-Request-Id")
          ruby_initiated = request_id&.start_with?("_RB_") || false
          payload.instance_variable_set(:@ruby_initiated, ruby_initiated)
          trusted_ruby_initiated = ruby_initiated && (payload.master? == true)
        else
          ruby_initiated = false
          trusted_ruby_initiated = false
        end

        # Pre-block: apply declarative write protection (guard :field, :mode)
        # to the parse_object that the handler will receive. Running BEFORE
        # the handler block means trusted server-side writes performed inside
        # the block are preserved -- only client-supplied values for guarded
        # fields are reverted.
        #
        # Notably we do NOT gate this on ruby_initiated. That flag derives
        # from a client-controlled X-Parse-Request-Id header, so trusting it
        # to bypass write protection would allow a one-header attack. Master
        # key requests still bypass via the master:/payload.master? check.
        if type == :before_save && payload && payload.object?
          klass = (className.present? && className != "*") ? Parse::Object.find_class(className) : nil
          if klass && klass.respond_to?(:field_guards) && klass.field_guards.any?
            pre_obj = payload.parse_object # memoized; the handler sees this same instance
            if pre_obj.respond_to?(:apply_field_guards!)
              pre_obj.apply_field_guards!(
                master: payload.master? || false,
                is_new: payload.original.blank?
              )
            end
          end
        end

        if registry.is_a?(Array)
          result = registry.map { |hook| payload.instance_exec(payload, &hook) }.last
        else
          result = payload.instance_exec(payload, &registry)
        end

        if result.is_a?(Parse::Object)
          # if it is a Parse::Object, we will call the registered ActiveModel callbacks
          if type == :before_save
            # returning false from the callback block only runs the before_* callback
            # Skip prepare_save! when this request is trusted-Ruby-initiated
            # (both `_RB_` header AND master key), since Parse-Stack already
            # ran ActiveModel before_save callbacks locally. A client-spoofed
            # `_RB_` without master falls through and runs them here.
            unless trusted_ruby_initiated
              before_save_result = result.run_before_save_callbacks
              # If a before_save callback halted the chain (returned false), reject the save.
              if before_save_result == false
                raise Parse::Webhooks::ResponseError, "Save halted by before_save callback"
              end
              # Parse Server exposes no separate beforeCreate trigger, so the
              # beforeSave hook is the single point at which before_create must
              # run for a client-initiated create. Run it AFTER before_save, for
              # new objects only -- matching ActiveModel order (before_save wraps
              # before_create) and mirroring the afterSave hook, which runs
              # after_create then after_save. `original.nil?` marks a create.
              if payload && payload.original.nil?
                create_result = result.run_before_create_callbacks
                if create_result == false
                  raise Parse::Webhooks::ResponseError, "Save halted by before_create callback"
                end
              end
            end
            # For before_save, return the changes payload (what Parse Server expects)
            result = result.changes_payload
          elsif type == :before_delete
            result.run_callbacks(:destroy) { false }
            result = true
          end
        elsif type == :before_save && result == false
          # If webhook block returns false, halt the save by throwing an error
          raise Parse::Webhooks::ResponseError, "Save halted by before_save webhook"
        elsif type == :before_save && (result == true || result.nil?)
          # Open Source Parse server does not accept true results on before_save hooks.
          result = {}
        end

        # Guard-injection: when a handler returns a Hash (or true/nil normalized
        # to {}) for a class with field_guards, Parse Server would otherwise
        # merge the response with the client's original payload and persist
        # the client-supplied values for guarded fields. Inject the pre-built
        # parse_object's changes_payload entries for any guarded field so the
        # response carries the appropriate revert (Delete op on create, prior
        # value on update). The Parse::Object return path already runs through
        # changes_payload on the same memoized instance and therefore needs no
        # extra injection.
        if type == :before_save && result.is_a?(Hash) && payload && payload.object?
          guard_klass = (className.present? && className != "*") ? Parse::Object.find_class(className) : nil
          if guard_klass && guard_klass.respond_to?(:field_guards) && guard_klass.field_guards.any?
            pre_obj = payload.parse_object # same memoized instance the pre-block step mutated
            if pre_obj.respond_to?(:changes_payload)
              guard_payload = pre_obj.changes_payload
              field_map = guard_klass.respond_to?(:field_map) ? guard_klass.field_map : {}
              guard_klass.field_guards.each_key do |field|
                remote = (field_map[field.to_sym] || field).to_s
                result[remote] = guard_payload[remote] if guard_payload.key?(remote)
              end
            end
          end
        end

        if type == :after_save && (result == true || result.nil?) && payload&.parse_object.present? && payload.parse_object.is_a?(Parse::Object)
          # Handle after_save callbacks intelligently based on request origin.
          # For trusted-Ruby-initiated saves (both `_RB_` header AND master
          # key), Parse Stack's local `run_callbacks :save` will fire
          # after_create and after_save callbacks after the REST response
          # returns; firing them again here would double-fire any side
          # effect (e.g. an `after_save :send_email` would send two emails
          # per save). For everything else -- client-initiated saves, or a
          # spoofed `_RB_` from a non-master client -- Parse Stack never had
          # a chance to run callbacks, so we fire them here.
          is_new = payload.original.nil?
          unless trusted_ruby_initiated
            payload.parse_object.run_after_create_callbacks if is_new
            payload.parse_object.run_after_save_callbacks
          end
          result = true
        end

        result
      end

      # Generates a success response for Parse Server.
      # @param data [Object] the data to send back with the success.
      # @return [Hash] a success data payload
      def success(data = true)
        { success: data }.to_json
      end

      # Generates an error response for Parse Server.
      # @param data [Object] the data to send back with the error.
      # @return [Hash] a error data payload
      def error(data = false)
        { error: data }.to_json
      end

      # @!attribute key
      # Returns the configured webhook key if available. By default it will use
      # the value of ENV['PARSE_SERVER_WEBHOOK_KEY'] if not configured.
      # @return [String]
      def key=(value)
        @key = value
        # Reset the warn-once flag so a deployment that configures the key
        # after startup gets a clean state if the key is later cleared.
        @missing_key_warned = nil
      end

      def key
        @key ||= ENV["PARSE_SERVER_WEBHOOK_KEY"] || ENV["PARSE_WEBHOOK_KEY"]
      end

      # When no webhook key is configured, the endpoint refuses requests by
      # default. Set this to true (or set PARSE_WEBHOOK_ALLOW_UNAUTHENTICATED=true)
      # to opt into the legacy permissive behavior for local development.
      # @return [Boolean]
      attr_writer :allow_unauthenticated

      def allow_unauthenticated
        return @allow_unauthenticated unless @allow_unauthenticated.nil?
        ENV["PARSE_WEBHOOK_ALLOW_UNAUTHENTICATED"] == "true"
      end

      # When set, {Parse::Webhooks::Registration#assert_webhook_url_safe!}
      # skips the DNS resolution and private/internal CIDR refusal. Other
      # checks (scheme, userinfo, host presence) still apply. Intended for
      # integration tests that register webhooks at Docker bridge hosts
      # (e.g. +host.docker.internal+) which only resolve from inside the
      # Parse Server container. May also be enabled via
      # +PARSE_WEBHOOK_ALLOW_PRIVATE_URLS=true+. Do not enable in
      # production: the resolution guard is what blocks attacker-driven
      # webhook redirection to internal hosts.
      # @return [Boolean]
      attr_writer :allow_private_webhook_urls

      def allow_private_webhook_urls
        return @allow_private_webhook_urls unless @allow_private_webhook_urls.nil?
        ENV["PARSE_WEBHOOK_ALLOW_PRIVATE_URLS"] == "true"
      end

      # Standard Rack call method. This method processes an incoming cloud code
      # webhook request from Parse Server, validates it and executes any registered handlers for it.
      # The result of the handler for the matching webhook request is sent back to
      # Parse Server. If the handler raises a {Parse::Webhooks::ResponseError},
      # it will return the proper error response.
      # @raise Parse::Webhooks::ResponseError whenever {Parse::Object}, ActiveModel::ValidationError
      # @param env [Hash] the environment hash in a Rack request.
      # @return [Array] the value of calling `finish` on the {http://www.rubydoc.info/github/rack/rack/Rack/Response Rack::Response} object.
      def call(env)
        # Thraed safety
        dup.call!(env)
      end

      # @!visibility private
      def call!(env)
        request = Rack::Request.new env
        response = Rack::Response.new

        if self.key.present?
          provided_key = request.env[HTTP_PARSE_WEBHOOK].to_s
          unless ActiveSupport::SecurityUtils.secure_compare(self.key, provided_key)
            puts "[Parse::Webhooks] Invalid Parse-Webhook Key received"
            response.write error("Invalid Parse Webhook Key")
            return response.finish
          end
        elsif !self.allow_unauthenticated
          # Fail closed: without a configured webhook key, any host on the
          # network could fire authenticated cloud triggers. Set
          # PARSE_SERVER_WEBHOOK_KEY (matching the Parse Server config) or
          # opt in to permissive mode via PARSE_WEBHOOK_ALLOW_UNAUTHENTICATED=true.
          # Log the warning only once; otherwise an attacker hammering the
          # endpoint can fill disk with repeated warnings. The flag lives on
          # the original Parse::Webhooks class (not the per-request dup created
          # by `call`), so it persists across requests.
          unless Parse::Webhooks.instance_variable_get(:@missing_key_warned)
            Parse::Webhooks.instance_variable_set(:@missing_key_warned, true)
            warn "[Parse::Webhooks] Refusing requests: no webhook key configured. " \
                 "Set PARSE_SERVER_WEBHOOK_KEY or Parse::Webhooks.allow_unauthenticated = true."
          end
          response.write error("Webhook key not configured.")
          return response.finish
        end

        # Use Rack's media_type (strips parameters/whitespace and lowercases)
        # so the comparison is exact. The previous substring check on the raw
        # Content-Type header accepted look-alikes like "application/jsonp"
        # or "text/application/json" that should be rejected.
        unless request.media_type == CONTENT_TYPE
          response.write error("Invalid content-type format. Should be application/json.")
          return response.finish
        end

        request.body.rewind
        body_str = request.body.read
        if body_str.bytesize > 1_048_576
          response.write error("Payload too large.")
          return response.finish
        end

        # NEW-EXT-4: reject in-window replays and (when configured)
        # require a fresh HMAC over the body. Done before JSON parsing so
        # a malformed payload can't bypass dedup, and before any handler
        # runs so side effects aren't repeated.
        replay_error = ReplayProtection.verify!(
          request.env,
          body_str,
          request.env["HTTP_X_PARSE_REQUEST_ID"]
        )
        if replay_error
          response.write error(replay_error)
          return response.finish
        end

        begin
          payload = Parse::Webhooks::Payload.new body_str
        rescue => e
          warn "Invalid webhook payload format: #{e}"
          response.write error("Invalid payload format. Should be valid JSON.")
          return response.finish
        end

        if self.logging.present?
          if payload.trigger?
            puts "[Webhooks::Request] --> #{payload.trigger_name} #{payload.parse_class}:#{payload.parse_id}"
          elsif payload.function?
            puts "[ParseWebhooks Request] --> Function #{payload.function_name}"
          end
          if self.logging == :debug
            puts "[Webhooks::Payload] ----------------------------"
            puts Parse::Middleware::BodyBuilder.redact(payload.as_json.to_json)
            puts "----------------------------------------------------\n"
          end
        end

        begin
          result = true
          if payload.function? && payload.function_name.present?
            result = Parse::Webhooks.call_route(:function, payload.function_name, payload)
          elsif payload.trigger? && payload.parse_class.present? && payload.trigger_name.present?
            # call hooks subscribed to the specific class
            result = Parse::Webhooks.call_route(payload.trigger_name, payload.parse_class, payload)

            # call hooks subscribed to any class route
            generic_result = Parse::Webhooks.call_route(payload.trigger_name, "*", payload)
            result = generic_result if generic_result.present? && result.nil?
          else
            if self.logging.present?
              puts "[Webhooks] --> Could not find mapping route for " \
                   "#{Parse::Middleware::BodyBuilder.redact(payload.to_json)}"
            end
          end

          result = true if result.nil?
          if self.logging.present?
            puts "[Webhooks::Response] ----------------------------"
            puts success(result)
            puts "----------------------------------------------------\n"
          end
          response.write success(result)
          return response.finish
        rescue Parse::Webhooks::ResponseError, ActiveModel::ValidationError => e
          if payload.trigger?
            puts "[Webhooks::ResponseError] >> #{payload.trigger_name} #{payload.parse_class}:#{payload.parse_id}: #{e}"
          elsif payload.function?
            puts "[Webhooks::ResponseError] >> #{payload.function_name}: #{e}"
          end
          response.write error(e.to_s)
          return response.finish
        end

        #check if we can handle the type trigger/functionName
        response.write(success)
        response.finish
      end # call
    end #class << self
  end # Webhooks
end # Parse

# Load-order fixup for {Parse::Core::FieldGuards}: classes that declared
# `guard` in their class body (e.g. {Parse::User}) ran before this file
# was required, so their `ensure_field_guards_webhook!` call short-circuited
# with a "Parse::Webhooks not yet defined" guard. Walk every Parse::Object
# subclass that ended up with a non-empty `field_guards` hash and register
# the stub route now that {Parse::Webhooks} exists. Application code that
# uses `guard` from its own model files (which are required after this
# file) hits the normal path and bypasses this fixup.
if defined?(Parse::Object) && Parse::Object.respond_to?(:descendants)
  Parse::Object.descendants.each do |klass|
    next unless klass.respond_to?(:field_guards) && klass.field_guards.any?
    next unless klass.respond_to?(:ensure_field_guards_webhook!)
    klass.ensure_field_guards_webhook!
  end
end
