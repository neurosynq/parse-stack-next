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
require_relative "terminal_safe"
# Note: Do not require "stack" here - this file is loaded from stack.rb
# and adding that require would create a circular dependency.
require_relative "model/object"
require_relative "webhooks/payload"
require_relative "webhooks/registration"
require_relative "webhooks/replay_protection"
require_relative "webhooks/trigger_audit"

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
    #
    # An optional numeric `code` is carried on the exception and written into
    # the error body as `"code"`. Note that Parse Server's HTTP webhook adapter
    # (as of 9.10) reports every webhook error to the client as code 141
    # (`SCRIPT_FAILED`) and does not forward a custom code; the code remains
    # visible to in-process callers such as {Parse::Webhooks.run_function}.
    class ResponseError < StandardError
      # @return [Integer, nil] the Parse error code requested by the handler.
      attr_reader :code

      # @param message [String] the error message.
      # @param code [Integer, nil] an optional Parse error code.
      def initialize(message = nil, code: nil)
        super(message)
        @code = code
      end
    end

    # The reply that tells Parse Server to keep a beforeSave write, or the
    # afterFind rows, exactly as they were: a JSON object with no `success`
    # key, so the adapter's `body.success` is `undefined`. A `null` success
    # is not safe for beforeSave (see {Parse::Webhooks.before_save_reply}).
    PASS_THROUGH_BODY = "{}"

    # Keys never echoed back to Parse Server in a beforeSave reply. These are
    # server-managed (`className`, timestamps) or credential material that a
    # client write cannot legitimately carry.
    # @!visibility private
    BEFORE_SAVE_REPLY_SKIP_KEYS = %w[
      className createdAt updatedAt
      sessionToken session_token _hashed_password _password_history
    ].freeze

    # The authentication-side triggers (local underscore form). These carry a
    # `_User` / `_Session` as the payload object but are NOT object save/delete
    # triggers: the router runs no ActiveModel save/create/destroy callbacks for
    # them, and Parse Server ignores their response body.
    AUTH_TRIGGERS = %i[
      before_login after_login after_logout before_password_reset_request
    ].freeze

    # The LiveQuery triggers (local underscore form). Connection-global or
    # event-scoped; Parse Server ignores their response body. Delivered over an
    # HTTP webhook only in a co-located single-process LiveQuery setup.
    LIVE_QUERY_TRIGGERS = %i[before_connect before_subscribe after_event].freeze

    # Every trigger whose payload is not an object save/delete/find shape.
    # Parse Server's webhook response handler resolves `{}` for all of these
    # (the body is ignored), so the router normalizes their handler result to a
    # success no-op rather than serializing a returned object into the response.
    NON_OBJECT_TRIGGERS = (AUTH_TRIGGERS + LIVE_QUERY_TRIGGERS).freeze

    # The `before*` subset of {NON_OBJECT_TRIGGERS} for which a handler can DENY
    # the operation. Parse Server only treats an `{error}` response as a
    # rejection -- a `{success:false}` body resolves and lets the login /
    # connect / subscribe / reset proceed. So, mirroring the `before_save`
    # convention, the router converts a `false` return from one of these into a
    # {ResponseError} (which serializes to `{error}`). `error!` works for any
    # trigger; the `after*` variants fire after the fact and cannot undo it.
    REJECTABLE_NON_OBJECT_TRIGGERS = %i[
      before_login before_password_reset_request before_connect before_subscribe
    ].freeze

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

      # Whether an exception raised by one `after_*` handler prevents the
      # remaining handlers for that same trigger from running.
      #
      # Only the accumulating, non-rejectable `after_*` triggers can have more
      # than one handler (see {Parse::Webhooks::Registration#route}), so this
      # governs `after_save`, `after_delete`, and `after_logout` and nothing
      # else. `before_*` dispatch is untouched: a raise there is how a handler
      # denies an operation, and it must continue to abort.
      #
      # Defaults to `true`, which is the historical behavior. Handlers are
      # folded with `Array#map`, and `map` abandons the collection on the first
      # raise, so a handler that raises silently prevents every handler
      # registered after it from running. That ordering is not something an
      # application fully controls: the SDK's own cache-invalidation triggers
      # install during `Parse.setup` and therefore sit ahead of handlers
      # registered by application files loaded later.
      #
      # Set to `false` to isolate handlers from each other, so that each one
      # runs regardless of what an earlier one raised. The error is reported
      # (a warning plus a `parse.webhooks.handler_error` notification) and
      # dispatch continues.
      #
      # Either way, nothing is reverted. An `after_*` trigger fires once the
      # write has already committed, so there is no version of this setting
      # that can undo the save; the only question it answers is whether the
      # remaining handlers still get to run.
      #
      # @example Keep one failing handler from starving the others
      #   Parse::Webhooks.abort_after_callbacks_on_error = false
      #
      # @return [Boolean]
      attr_writer :abort_after_callbacks_on_error

      # (see #abort_after_callbacks_on_error=)
      # @return [Boolean]
      def abort_after_callbacks_on_error
        return @abort_after_callbacks_on_error unless @abort_after_callbacks_on_error.nil?
        true
      end

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
        # Parse Server has no beforeCreate/afterCreate webhook trigger; the
        # create variants are ActiveModel callbacks that run inside the
        # beforeSave/afterSave handler for new objects. Point callers there
        # rather than registering a route that can never fire.
        if type == :before_create || type == :after_create
          save = type == :before_create ? :before_save : :after_save
          raise ArgumentError,
                "There is no #{type} webhook. Register `webhook :#{save}` instead — " \
                "your #{type} ActiveModel callbacks run inside the #{save} handler " \
                "for new objects (registering #{save} enables BOTH the #{save} and " \
                "#{type} callbacks)."
        end
        if routes[type].nil? || block.respond_to?(:call) == false
          raise ArgumentError, "Invalid Webhook registration trigger #{type} #{className}"
        end

        # Triggers whose handlers compose instead of replacing one another.
        #
        # `after_save` / `after_delete` have always accumulated. The remaining
        # `after_*` triggers are added because the SDK itself now registers
        # them for cache invalidation: without this, registering an internal
        # `after_logout` handler would silently replace an application's own,
        # with the winner decided by file load order and no warning.
        #
        # This is safe only for non-rejectable triggers. Parse Server ignores
        # their response body, and {#call_route} normalizes their result to
        # `true` regardless, so `.last` semantics are irrelevant.
        # {REJECTABLE_NON_OBJECT_TRIGGERS} are deliberately excluded: a
        # composite of those must deny if ANY handler denies, and folding with
        # `.last` would discard an earlier rejection.
        composable = type == :after_save || type == :after_delete ||
                     (NON_OBJECT_TRIGGERS.include?(type) &&
                      !REJECTABLE_NON_OBJECT_TRIGGERS.include?(type) &&
                      type.to_s.start_with?("after_"))

        if composable
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

      # Evaluate a single registered handler block in the scope of the payload.
      #
      # The block runs with `self` bound to the {Parse::Webhooks::Payload}, so a
      # handler can call `parse_object`, `params`, `error!`, etc. directly --
      # exactly as it could under the historical `payload.instance_exec(payload,
      # &block)` invocation. The difference is the return semantics:
      #
      # - `return value` returns `value` as the handler result (instead of the
      #   `LocalJumpError: unexpected return` that bare `instance_exec` raised
      #   when the block was defined inside a method).
      # - The legacy idioms still work unchanged: the last expression's value,
      #   `next value`, and `break value` all return `value`, and `raise`
      #   propagates untouched (so `error!` / before_save rejections behave the
      #   same).
      #
      # This is achieved by attaching the block as a singleton method on the
      # per-request payload (so `return` gets method semantics) and removing it
      # afterward. The payload is a per-request instance, so this neither leaks
      # nor mutates shared state across threads.
      #
      # Arity is matched to the old `instance_exec(payload, ...)` contract: a
      # zero-arity block (`do ... end` / `proc { }`) is called with no args; a
      # block that declares a parameter (`do |payload| ... end`) or a splat
      # receives the payload.
      #
      # Run every handler registered for one accumulating `after_*` trigger.
      #
      # `.last` is preserved as the composed result because Parse Server
      # ignores the response body for these triggers and {#call_route}
      # normalizes it anyway, so which handler's value survives is not
      # observable.
      #
      # When {abort_after_callbacks_on_error} is false, a handler that raises
      # is reported and skipped rather than taking the rest of the trigger down
      # with it. Nothing is reverted in either mode: the write these triggers
      # fire on has already committed.
      #
      # @param payload [Parse::Webhooks::Payload] the request payload.
      # @param registry [Array<Proc>] the handlers, in registration order.
      # @param type [Symbol] the trigger being dispatched.
      # @return [Object] the last handler result.
      def dispatch_composed(payload, registry, type)
        return registry.map { |hook| invoke_handler(payload, hook) }.last if
          abort_after_callbacks_on_error

        last = nil
        registry.each do |hook|
          begin
            last = invoke_handler(payload, hook)
          rescue StandardError => e
            report_handler_error(type, e)
          end
        end
        last
      end

      # Report a handler failure that was isolated rather than propagated.
      #
      # The message is included because an application's own handler raised it
      # and the application needs it to debug; this is not the SDK's internal
      # `guard`, which deliberately omits messages that can carry a cache key.
      #
      # @param type [Symbol] the trigger being dispatched.
      # @param error [StandardError] the raised error.
      # @return [void]
      def report_handler_error(type, error)
        # The handler's message is application-authored but routinely quotes the
        # payload that triggered it, which is caller-controlled.
        warn "[Parse::Webhooks] #{type} handler raised #{error.class}: " \
             "#{Parse::TerminalSafe.sanitize_line(error.message)}; " \
             "continuing with the remaining handlers " \
             "(Parse::Webhooks.abort_after_callbacks_on_error is false)"
        return unless defined?(ActiveSupport::Notifications)
        begin
          ActiveSupport::Notifications.instrument(
            "parse.webhooks.handler_error", trigger: type, error: error.class.name,
          )
        rescue StandardError
          nil
        end
      end

      # @param payload [Parse::Webhooks::Payload] the request payload (becomes `self`).
      # @param block [Proc] the registered handler block.
      # @return [Object] the handler's result value.
      def invoke_handler(payload, block)
        name = :"__parse_webhook_handler_#{block.object_id}__"
        payload.define_singleton_method(name, &block)
        handler = payload.method(name)
        begin
          # Match the old `payload.instance_exec(payload, &block)` arity
          # leniency: a zero-arity block is called bare; otherwise it receives
          # the payload, plus a nil for each additional REQUIRED positional so a
          # block declaring `|payload, extra|` (or more) does not raise — under
          # instance_exec those surplus params were silently nil. `arity` is
          # negative for optional/splat params (e.g. -1 for `|*a|`, -2 for
          # `|a, *b|`); `~arity` gives the required count in that case.
          if handler.arity == 0
            handler.call
          else
            required = handler.arity.negative? ? ~handler.arity : handler.arity
            handler.call(payload, *Array.new([required - 1, 0].max))
          end
        ensure
          singleton = payload.singleton_class
          if singleton.method_defined?(name) || singleton.private_method_defined?(name)
            singleton.send(:remove_method, name)
          end
        end
      end

      # Run any {Parse::Webhooks::Payload#after_response} callbacks a handler
      # registered, AFTER the response has been produced. Prefers the server's
      # `rack.after_reply` hook (Puma / Unicorn), which fires once the response
      # is flushed to the socket on the same worker thread; falls back to a
      # detached thread when the server does not provide it (e.g. WEBrick). Each
      # callback is isolated so one raising neither aborts the others nor reaches
      # the client. No-op when nothing was deferred.
      #
      # @param env [Hash] the Rack environment (for `rack.after_reply`).
      # @param payload [Parse::Webhooks::Payload, nil] the request payload.
      # @return [void]
      def dispatch_deferred(env, payload)
        return if payload.nil? || !payload.respond_to?(:deferred_callbacks)
        callbacks = payload.deferred_callbacks
        return if callbacks.blank?

        runner = proc do
          callbacks.each do |cb|
            begin
              cb.call
            rescue => e
              warn "[Webhooks::after_response] deferred callback raised: #{e.class}: #{e.message}"
            end
          end
        end

        # Enqueueing must never break an otherwise-successful response: this runs
        # just before `response.finish`, so a raise here (a frozen after_reply
        # array, thread exhaustion) would discard the buffered reply and surface
        # as a 500. Failing to schedule deferred work degrades to "not run",
        # never to a failed response.
        begin
          after_reply = env.is_a?(Hash) ? env["rack.after_reply"] : nil
          if after_reply.respond_to?(:<<)
            after_reply << runner
          else
            Thread.new(&runner)
          end
        rescue => e
          warn "[Webhooks::after_response] could not schedule deferred work: #{e.class}: #{e.message}"
        end
        nil
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
          # `master?` is the authenticated claim: on unauthenticated ingress
          # it is false, so a forged `_RB_` id plus `"master": true` cannot
          # suppress model callbacks.
          trusted_ruby_initiated = ruby_initiated && payload.master?
        else
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
                is_new: payload.original.blank?,
              )
              # A guard revert is not the handler assigning the ACL.
              pre_obj.reset_webhook_handler_acl_assigned! if pre_obj.respond_to?(:reset_webhook_handler_acl_assigned!)
            end
          end
        end

        if registry.is_a?(Array)
          # An Array registry only ever exists for the accumulating,
          # non-rejectable `after_*` triggers, so isolating handlers here
          # cannot affect `before_*` rejection semantics.
          result = dispatch_composed(payload, registry, type)
        else
          result = invoke_handler(payload, registry)
        end

        if type == :after_find
          # Parse Server can only keep or deny afterFind rows from an HTTP
          # webhook (see after_find_reply!); the reply always passes them through.
          return after_find_reply!(payload, result)
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
              adopt_request_user_as_acl_owner!(payload, result)
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
            # Parse Server REPLACES the write with the object a beforeSave
            # webhook returns, so reply with the client's full write plus the
            # handler's changes (or `nil`, "unchanged", when there are none).
            result = before_save_reply(payload, result, include_create_defaults: true)
          elsif type == :before_delete
            # Run only the BEFORE phase of the destroy chain: the object is not
            # deleted yet, so after_destroy belongs to the afterDelete trigger.
            # A halted chain must deny the delete, and Parse Server only treats
            # an `{error}` body as a denial.
            unless trusted_ruby_initiated
              if result.send(:run_before_phase_callbacks, :destroy) == false
                raise Parse::Webhooks::ResponseError, "Delete halted by before_destroy callback"
              end
            end
            result = true
          end
        elsif type == :before_save && result == false
          # If webhook block returns false, halt the save by throwing an error
          raise Parse::Webhooks::ResponseError, "Save halted by before_save webhook"
        elsif type == :before_save
          # `true` / `nil` (or any non-Hash value) means "allow the write as
          # sent". A Hash is a set of field overrides. Either way the reply is
          # built from the client's write so nothing the client sent is lost;
          # in-place edits to `parse_object` and field-guard reverts are
          # carried along. `nil` tells Parse Server to keep the write as is.
          overrides = result.is_a?(Hash) ? result : nil
          result = before_save_reply(payload, payload&.memoized_parse_object, overrides: overrides)
        elsif type == :before_delete && result == false
          # Parse Server ignores a `{success:false}` body and deletes anyway;
          # only an `{error}` body denies the delete.
          raise Parse::Webhooks::ResponseError, "Delete halted by before_delete webhook"
        end

        # Auth- and LiveQuery-trigger dispatch (beforeLogin/afterLogin/
        # afterLogout/beforePasswordResetRequest, beforeConnect/beforeSubscribe/
        # afterEvent). Parse Server IGNORES the response body for all of these --
        # its webhook response handler resolves {} regardless -- so the ONLY way
        # a handler can affect the operation is the error path, and only for the
        # "before" variants (a login/connect/subscribe/reset can be denied; an
        # after_* fires after the fact and cannot be undone).
        #
        # Crucially, Parse Server treats only an {error} response as a rejection:
        # a {success:false} body RESOLVES and lets the operation proceed. So a
        # handler that returns `false` to "deny login" would silently allow it.
        # We mirror the before_save convention and convert that false into a
        # ResponseError (=> {error} => Parse Server denies). `error!` works for
        # any of them (the call! rescue converts it). Every other return value --
        # including a Parse::Object a handler happened to return (e.g. the _User
        # from beforeLogin) -- is normalized to a success no-op so we never
        # serialize an object into the response or the redacted request log.
        if NON_OBJECT_TRIGGERS.include?(type)
          if result == false && REJECTABLE_NON_OBJECT_TRIGGERS.include?(type)
            raise Parse::Webhooks::ResponseError, "#{type} rejected by webhook handler"
          end
          result = true
        end

        # Field guards need no separate injection step: the pre-block step
        # reverted the guarded fields on the memoized parse_object, and
        # before_save_reply diffs that same instance against the client's
        # write, so every revert is already in the reply.

        if type == :after_save && payload&.parse_object.present? && payload.parse_object.is_a?(Parse::Object)
          # The chained ActiveModel after_save/after_create callbacks are NOT
          # fired here. `call!` dispatches every trigger twice -- once for the
          # specific class route and once for the generic `"*"` route -- so
          # firing the model callbacks inside this per-route block double-fired
          # them for any app that registered BOTH a class route and a `"*"`
          # route (e.g. an `after_save :send_email` would send two emails per
          # save). The dispatch now lives in `run_after_save_chain`, which
          # `call!` invokes exactly once per delivery after both route calls.
          #
          # We still normalize the result to `true` so a handler that returned
          # the parse_object (the recommended before_save pattern, easy to copy
          # by mistake) never leaks an object into the response or the log.
          result = true
        end

        result
      end

      # Fires the chained ActiveModel after_save (and after_create, for a new
      # object) callbacks for an afterSave delivery -- exactly once per request.
      #
      # This lives in `call!` rather than `call_route` because `call!` dispatches
      # every trigger twice (the specific class route AND the generic `"*"`
      # route). Firing the model callbacks per-route would double-fire any side
      # effect for an app that registered both routes. Calling this once, after
      # both route calls, fires the chain exactly once regardless of how many
      # routes matched.
      #
      # The decision to fire depends ONLY on request origin, never on what a
      # handler returned: Parse Server discards the afterSave response body
      # entirely, so a handler returning the parse_object must not suppress the
      # callbacks. For trusted-Ruby-initiated saves (both the `_RB_` request-id
      # header AND the master key) Parse Stack's local `run_callbacks :save`
      # already fires these after the REST response returns, so we skip them
      # here to avoid the double-fire. The route-present guard preserves the
      # "an unregistered afterSave trigger never fires model callbacks" contract
      # that `call_route`'s early return used to provide.
      #
      # @param payload [Parse::Webhooks::Payload] the afterSave payload.
      # @return [void]
      def run_after_save_chain(payload)
        return unless payload&.after_save?
        return unless payload.parse_object.is_a?(Parse::Object)

        # Preserve the "no registered route => no model callbacks" behavior that
        # call_route's `return unless routes[type][className].present?` enforced.
        # Mirror that guard exactly: key on parse_class.to_s (as call_route does)
        # and use `.present?` on the value -- registration stores an Array, and an
        # empty/absent registration must NOT fire (matching the original).
        after_save_routes = routes[:after_save]
        return unless after_save_routes &&
                      (after_save_routes[payload.parse_class.to_s].present? ||
                       after_save_routes["*"].present?)

        # Trusted-Ruby-initiated saves run their callbacks locally; firing again
        # here would double them. This must match call_route's trusted_ruby_initiated
        # EXACTLY. call_route runs (and stamps @ruby_initiated) before this for any
        # matched route, so read that stamped value rather than recomputing via
        # `ruby_initiated?` -- whose `||=` memoization re-derives on a stamped
        # `false` and could disagree with call_route's header lookup.
        return if payload.ruby_initiated? && payload.master?

        # By the time afterSave fires the object is ALREADY persisted in Parse
        # Server, and Parse Server discards the afterSave response body entirely
        # (it resolves success even if the handler throws). So a chained callback
        # that raises must not (a) 500 the webhook endpoint -- `call!`'s rescue
        # only catches ResponseError / ValidationError, so a bare StandardError
        # would escape -- nor (b) take out the OTHER phase's unrelated side
        # effects. Run the after_create and after_save phases independently, each
        # guarded, logging and swallowing any StandardError. This mirrors Parse's
        # own afterSave semantics (log-and-continue on a post-persist failure):
        # a raising `after_create :send_welcome_email` no longer silently skips
        # an unrelated `after_save :reindex`, and neither can crash the endpoint.
        obj = payload.parse_object
        run_after_save_phase(obj, :after_create) if payload.original.nil?
        run_after_save_phase(obj, :after_save)
        nil
      end

      # Runs one phase (:after_create or :after_save) of an afterSave object's
      # chained ActiveModel callbacks, swallowing and logging any StandardError
      # so a post-persist callback failure can't crash the webhook endpoint or
      # suppress the sibling phase. ActiveModel still halts the rest of *this*
      # phase's chain on a raise -- only the cross-phase / endpoint blast radius
      # is contained here. Note this also swallows a ResponseError/ValidationError
      # raised from inside an after_save callback: afterSave is post-persist and
      # Parse Server discards the response body, so an `error!` there cannot deny
      # the (already-committed) write -- it is logged, not propagated.
      # @param obj [Parse::Object] the persisted afterSave object.
      # @param phase [Symbol] :after_create or :after_save.
      # @return [void]
      def run_after_save_phase(obj, phase)
        case phase
        when :after_create then obj.run_after_create_callbacks
        when :after_save then obj.run_after_save_callbacks
        end
        nil
      rescue => e
        # Redact the exception message before logging: a callback error can echo
        # record contents/tokens, and the rest of this file routes log output
        # through the same redactor.
        warn "[Parse::Webhooks] afterSave #{phase} callback raised for " \
             "#{obj.class}##{Parse::TerminalSafe.sanitize_line(obj.id)} -- the object is " \
             "already persisted; logging and continuing: #{e.class}: " \
             "#{Parse::TerminalSafe.sanitize_line(Parse::Middleware::BodyBuilder.redact(e.message))}"
        nil
      end

      # Fires the chained ActiveModel after_destroy callbacks for an afterDelete
      # delivery, exactly once per request (after both the class route and the
      # `"*"` route ran), mirroring {run_after_save_chain}. Skipped for
      # trusted-Ruby-initiated deletes, whose callbacks already ran locally
      # around `destroy`, and when no afterDelete route is registered. The
      # object is already gone, so a raising callback is logged and swallowed.
      #
      # @param payload [Parse::Webhooks::Payload] the afterDelete payload.
      # @return [void]
      def run_after_delete_chain(payload)
        obj = nil
        return unless payload&.after_delete?
        obj = payload.parse_object
        return unless obj.is_a?(Parse::Object)
        return unless route_registered?(:after_delete, payload.parse_class)
        return if payload.ruby_initiated? && payload.master?
        obj.run_after_delete_callbacks
        nil
      rescue => e
        warn "[Parse::Webhooks] afterDelete after_destroy callback raised for " \
             "#{obj ? obj.class : "UnknownObject"}##{Parse::TerminalSafe.sanitize_line(obj&.id)} -- the object is " \
             "already deleted; logging and continuing: #{e.class}: " \
             "#{Parse::TerminalSafe.sanitize_line(Parse::Middleware::BodyBuilder.redact(e.message))}"
        nil
      end

      # Whether a handler is registered for a trigger on a class, either on the
      # class itself or on the generic `"*"` route.
      #
      # @param type [Symbol, String] the trigger (or `:function`).
      # @param class_name [String, nil] the class (or function) name.
      # @return [Boolean]
      def route_registered?(type, class_name)
        type = type.to_s.underscore.to_sym
        table = routes[type]
        return false if table.blank?
        return table[class_name.to_s].present? if type == :function
        table[class_name.to_s].present? || table["*"].present?
      end

      # Build the object a beforeSave webhook replies with.
      #
      # Parse Server's HTTP webhook adapter REPLACES the pending write with
      # whatever object a beforeSave webhook returns (`this.data =
      # response.object`). Replying with only the handler's changes therefore
      # erases every other field the client sent. This method returns:
      #
      # - `nil` when nothing differs from the client's write. The router
      #   replies with an empty object (`{}`, no `success` key), which Parse
      #   Server treats as "keep the write exactly as sent", preserving every
      #   atomic operator. (`{"success": null}` is NOT equivalent: Parse
      #   Server's beforeSave adapter checks `typeof result === "object"`,
      #   which is true for null, and then throws deleting a key from it.)
      # - otherwise a Hash: the client's write (rebuilt from the payload, with
      #   `Increment` / `Add` / `Remove` / `Delete` / relation operators passed
      #   through untouched) with the handler's changes layered on top. A field
      #   the handler (or a field guard) returned to its stored value is
      #   dropped from the write rather than rewritten.
      #
      # Fields are compared against a fresh build of the payload, so only the
      # fields the handler actually changed are encoded from the Ruby object.
      # A field the handler rewrites is written as an absolute value. An
      # operator on a dotted sub-key (`"meta.count"`) reaches the webhook only
      # as its resulting sub-document, so on an update a changed sub-document
      # is written back as dotted keys for just the sub-keys that differ from
      # the stored one. A concurrent write to another sub-key survives; the
      # changed sub-key itself is written as its resulting value. The split
      # is one level deep (a changed sub-key is written whole at
      # `field.sub`), and a field whose writes would carry a typed value is
      # written whole.
      #
      # @param payload [Parse::Webhooks::Payload] the beforeSave payload.
      # @param obj [Parse::Object, nil] the handler's object (nil when none).
      # @param overrides [Hash, nil] field values a handler returned as a Hash.
      # @param include_create_defaults [Boolean] on a create, also write the
      #   object's dirty fields the client did not send (declared defaults and
      #   the ACL the class policy resolves), matching what an SDK-side create
      #   sends.
      # @return [Hash, nil] the reply object, or nil for "unchanged".
      def before_save_reply(payload, obj, overrides: nil, include_create_defaults: false)
        return nil unless payload && payload.object?
        raw_object = payload.raw_object
        return nil unless raw_object.is_a?(Hash)
        raw_original = payload.raw_original
        raw_original = nil unless raw_original.is_a?(Hash) && raw_original.present?

        changes = {}
        drops = []
        if obj.is_a?(Parse::Object)
          changes, drops = handler_field_changes(payload, obj, raw_original)
          if include_create_defaults && raw_original.nil?
            client_keys = raw_object.keys.map(&:to_s)
            dirty = obj.changed.map(&:to_sym) & snapshot_fields(obj)
            # This includes the ACL. A create with no `ACL` key is stored by
            # Parse Server as public read and write, so a class with an ACL
            # policy always replies with the ACL that policy resolved (owned
            # by the requesting user where the policy names an owner; see
            # {adopt_request_user_as_acl_owner!}) or the ACL the handler set.
            # An ACL the client sent is kept as sent.
            wire_values(obj, dirty).each do |remote, value|
              next if client_keys.include?(remote) || changes.key?(remote)
              changes[remote] = value
            end
          end
          # An ACL the handler assigned on a create is written even when it
          # equals the default stamp or the client's ACL, whatever the handler
          # returned (the object, `true`, `nil`, or a Hash, whose own `ACL`
          # still wins below). Diffing alone misses `obj.acl = Parse::ACL.new`
          # under a `{}` default, and a create with no `ACL` key is stored
          # public read and write.
          if handler_assigned_acl?(obj) && !changes.key?("ACL")
            changes.merge!(wire_values(obj, [:acl]).slice("ACL"))
          end
        end
        overrides = overrides.as_json if overrides.is_a?(Hash)
        return nil if changes.empty? && drops.empty? && overrides.blank?

        reply = client_write_data(raw_object, raw_original)
        overrides = overrides.present? ? remote_override_keys(payload, overrides) : {}
        # A field the handler wrote or dropped replaces the client's dotted
        # sub-key writes for it; MongoDB refuses `meta` and `meta.x` together.
        (drops + changes.keys + overrides.keys).each do |remote|
          reply.delete_if { |key, _| key.start_with?("#{remote}.") }
        end
        drops.each { |remote| reply.delete(remote) }
        reply.merge!(changes)
        reply.merge!(overrides)
        fold_dotted_overrides!(reply, overrides.keys, raw_object: raw_object, create: raw_original.nil?)
        reply
      end

      # A handler's Hash override keyed by Ruby names (`{acl: ...}`,
      # `{author_name: ...}`) is mapped to the remote field names the reply
      # uses, so it replaces the matching field instead of sitting beside it.
      # A dotted key maps its first segment.
      # @!visibility private
      def remote_override_keys(payload, overrides)
        klass = begin
            name = payload.parse_class
            name.present? ? Parse::Object.find_class(name) : nil
          rescue StandardError
            nil
          end
        map = klass.respond_to?(:field_map) ? klass.field_map : {}
        overrides.each_with_object({}) do |(key, value), out|
          key = key.to_s
          head, rest = key.split(".", 2)
          remote = map[head.to_sym]
          head = remote.to_s if remote
          out[rest ? "#{head}.#{rest}" : head] = value
        end
      end

      # A handler's Hash override may name a sub-key (`"meta.y"`) of a field
      # the reply writes whole (a create, or a field written whole on an
      # update). MongoDB refuses `meta` and `meta.y` in one update, so the
      # sub-key write is folded into the whole value. An override deeper
      # than one level (`"meta.count.value"`) is folded into a `field.sub`
      # write seeded from the pending object, because Parse Server rebuilds
      # the afterSave object from a dotted key only one level deep. On a
      # create every dotted override folds into its whole field.
      #
      # When the value it folds into is not a plain sub-document, a client's
      # value is replaced by the handler's sub-key, and two of the handler's
      # own overrides that conflict (`"meta.a" => 5` with `"meta.a.b" => 6`)
      # raise {ResponseError}.
      # @!visibility private
      def fold_dotted_overrides!(reply, override_keys, raw_object: {}, create: false)
        handler_keys = override_keys.to_set
        override_keys.sort_by { |k| k.count(".") }.each do |key|
          next unless key.include?(".") && reply.key?(key)
          segments = key.split(".")
          # The nearest ancestor path the reply writes whole, if any.
          parent = (1...segments.length).map { |n| segments.first(n).join(".") }.reverse.find { |p| reply.key?(p) }
          unless parent
            next if !create && segments.length <= 2
            parent = create ? segments.first : segments.first(2).join(".")
            seed = parent.split(".").reduce(raw_object) { |cur, seg| cur.is_a?(Hash) ? cur[seg] : nil }
            reply[parent] = plain_sub_document?(seed) ? seed.deep_dup : {}
          end
          value = reply.delete(key)
          whole = reply[parent]
          if plain_sub_document?(whole)
            whole = whole.deep_dup
          elsif handler_keys.include?(parent)
            raise Parse::Webhooks::ResponseError,
                  "before_save reply: #{key} conflicts with #{parent} in the handler's reply"
          else
            whole = {}
          end
          *dirs, leaf = segments.drop(parent.count(".") + 1)
          node = dirs.reduce(whole) do |cur, dir|
            cur[dir] = {} unless plain_sub_document?(cur[dir])
            cur[dir]
          end
          if value.is_a?(Hash) && value.key?("__op")
            # A whole write stores its value as data, so an operator folded
            # into it is applied here rather than written as a Hash.
            result = fold_override_op(key, node[leaf], value)
            if result.equal?(FOLD_DELETE)
              node.delete(leaf)
            else
              node[leaf] = result
            end
          else
            node[leaf] = value
          end
          reply[parent] = whole
        end
        reply
      end

      # @!visibility private
      FOLD_DELETE = Object.new.freeze

      # Apply a handler's sub-key operator to the value it replaces inside a
      # sub-document the reply writes whole, with Parse Server's semantics
      # for that operator. Raises {ResponseError} (an `{error}` reply, so
      # Parse Server refuses the save) for an operator that cannot be applied
      # to a plain value, rather than storing the operator Hash as data.
      # @param key [String] the dotted override key, for the error message.
      # @param current [Object] the value at that path in the whole write.
      # @param op [Hash] the operator Hash (`{"__op" => ...}`).
      # @return [Object] the new value, or {FOLD_DELETE} to remove the key.
      # @!visibility private
      def fold_override_op(key, current, op)
        name = op["__op"]
        case name
        when "Delete"
          FOLD_DELETE
        when "Increment"
          amount = op["amount"]
          unless amount.is_a?(Numeric) && (current.nil? || current.is_a?(Numeric))
            raise Parse::Webhooks::ResponseError,
                  "before_save reply: cannot apply Increment to #{key} (#{current.class})"
          end
          (current || 0) + amount
        when "Add", "AddUnique", "Remove"
          objects = op["objects"]
          unless objects.is_a?(Array) && (current.nil? || current.is_a?(Array))
            raise Parse::Webhooks::ResponseError,
                  "before_save reply: cannot apply #{name} to #{key} (#{current.class})"
          end
          base = current || []
          case name
          when "Add" then base + objects
          when "AddUnique" then base + objects.reject { |o| base.include?(o) }.uniq
          else base.reject { |o| objects.include?(o) }
          end
        else
          raise Parse::Webhooks::ResponseError,
                "before_save reply: operator #{name.inspect} on #{key} cannot be combined " \
                "with a whole write of its parent field"
        end
      end

      # @!visibility private
      def handler_assigned_acl?(obj)
        return true if obj.instance_variable_get(:@_webhook_reply_acl) == true
        obj.respond_to?(:webhook_handler_acl_assigned?) && obj.webhook_handler_acl_assigned?
      end

      # On a client create, an owner-based ACL policy (`:owner_else_private`,
      # the shipped default, `:owner_else_public`, `:owner_but_public_read`)
      # resolves its owner the way an SDK create `as:` the requesting user
      # does: when the declared owner field holds no value, the user who made
      # the request owns the record. A request without a user (anonymous, or
      # master key) gets the policy's fallback. Leaves the object alone when
      # the handler or the client already set an ACL.
      # @!visibility private
      def adopt_request_user_as_acl_owner!(payload, obj)
        return unless payload && payload.original.nil?
        if handler_assigned_acl?(obj)
          # The handler's ACL is final: keep the save-time policy resolver
          # from replacing it, even when it equals the default stamp.
          obj.instance_variable_set(:@_acl_pristine, false)
          return
        end
        return unless obj.is_a?(Parse::Object) && obj.instance_variable_get(:@_acl_pristine)
        return if obj.instance_variable_get(:@_acl_owner_override)
        klass = obj.class
        return if klass.respond_to?(:builtin_acl_default_active?) && klass.builtin_acl_default_active?
        return unless klass.respond_to?(:acl_policy_setting) && klass.acl_policy_setting.to_s.start_with?("owner_")
        field = klass.acl_owner_field
        if field == :self
          adopt_self_owned_acl!(obj, klass)
          return
        end
        # A master-key request is not the user's own write.
        return if payload.master?
        user = payload.user
        return unless user.is_a?(Parse::User) && user.id.present?
        if field && obj.respond_to?(field)
          return if obj.send(field).present?
        end
        obj.instance_variable_set(:@_acl_owner_override, user)
      end

      # A self-owned user (`acl_policy ..., owner: :self`) owns its own
      # record, never the requesting user. Its objectId is assigned by Parse
      # Server after beforeSave, and Parse Server adds the new user's own
      # read and write to the ACL of every `_User` create. So the reply
      # carries the policy's ACL without the owner entry (`{}`, or public
      # read under `:owner_but_public_read`), which Parse Server completes
      # with the user's own grant. The save-time resolver is skipped, since
      # it would pre-generate an objectId the server does not use.
      # @!visibility private
      def adopt_self_owned_acl!(obj, klass)
        acl = if klass.acl_policy_setting == :owner_but_public_read
            Parse::ACL.everyone(true, false)
          else
            Parse::ACL.new
          end
        klass.instance_method(:acl=).bind_call(obj, acl)
        obj.instance_variable_set(:@_acl_pristine, false)
        obj.instance_variable_set(:@_webhook_reply_acl, true)
      end

      # The client's write, rebuilt from a beforeSave payload. Parse Server
      # serializes the pending object with `toJSON()`, which reports every
      # pending top-level operator as its operator hash, so the operators
      # survive here as sent. On an update, a field whose value equals the
      # stored one was not written by the client and is left out, and a
      # changed sub-document is split into dotted sub-key writes (see
      # {sub_document_write}).
      #
      # @param raw_object [Hash] the unscrubbed `object` hash.
      # @param raw_original [Hash, nil] the unscrubbed `original` hash.
      # @return [Hash]
      # @!visibility private
      def client_write_data(raw_object, raw_original)
        data = {}
        raw_object.each do |key, value|
          key = key.to_s
          next if BEFORE_SAVE_REPLY_SKIP_KEYS.include?(key)
          if raw_original
            # Parse Server drops objectId from an update write itself.
            next if key == Parse::Model::OBJECT_ID
            next if raw_original.key?(key) && raw_original[key] == value
            dotted = sub_document_write(key, value, raw_original[key])
            if dotted
              data.merge!(dotted)
              next
            end
          end
          data[key] = value
        end
        data
      end

      # Keys never split into dotted sub-key writes: their values are
      # replaced as a whole by Parse Server.
      # @!visibility private
      BEFORE_SAVE_REPLY_WHOLE_KEYS = %w[ACL authData].freeze

      # Dotted sub-key writes for a sub-document the client changed.
      #
      # Parse Server applies a client's `"meta.count"` operator to its pending
      # object and sends the webhook only the resulting `meta`, which matches
      # a whole-object write of the same value. Writing just the sub-keys that
      # differ from the stored sub-document gives the same result as either
      # client write, without overwriting sub-keys another request changed in
      # the meantime. The split is one level deep: a changed sub-key is
      # written whole at `field.sub`, nested objects included, because Parse
      # Server rebuilds the afterSave object from a non-operator dotted key
      # only one level deep (`"meta.count.value"` would set `meta.count` to
      # the leaf). A sub-key missing from the new value is written as a
      # `Delete` operator.
      #
      # Parse Server stores a dotted value as sent, without the type transform
      # a whole write gets, so a Date would land as a plain sub-document
      # instead of a BSON date. When any write would carry a typed value
      # (`{"__type": ...}`), the field is written whole instead.
      #
      # @param key [String] the top-level field name.
      # @param value [Object] the field's value in the pending object.
      # @param stored [Object] the field's stored value.
      # @return [Hash, nil] the dotted writes, or nil to write the field whole.
      # @!visibility private
      def sub_document_write(key, value, stored)
        return nil if key.start_with?("_") || BEFORE_SAVE_REPLY_WHOLE_KEYS.include?(key)
        return nil unless splittable_level?(value, stored)
        writes = {}
        diff_sub_document(key, value, stored, writes)
        return nil if writes.empty? || writes.values.any? { |v| typed_value?(v) }
        writes
      end

      # Collect the one-level dotted writes that turn `stored` into `value`
      # under `path`.
      # @!visibility private
      def diff_sub_document(path, value, stored, writes)
        (value.keys | stored.keys).each do |sub|
          new_present = value.key?(sub)
          old_present = stored.key?(sub)
          next if new_present && old_present && value[sub] == stored[sub]
          sub_path = "#{path}.#{sub}"
          writes[sub_path] = new_present ? value[sub] : { "__op" => "Delete" }
        end
      end

      # Whether a pair of values can be diffed key by key: both plain JSON
      # objects, with sub-keys that are usable as path segments.
      # @!visibility private
      def splittable_level?(value, stored)
        return false unless plain_sub_document?(value) && plain_sub_document?(stored)
        keys = value.keys | stored.keys
        return false if keys.empty?
        keys.none? { |k| k.to_s.empty? || k.to_s.include?(".") || k.to_s.start_with?("$") }
      end

      # Whether a JSON value is, or contains, a Parse typed value
      # (`{"__type": ...}`: Date, Bytes, Pointer, File, GeoPoint, ...).
      # @!visibility private
      def typed_value?(value)
        case value
        when Hash then value.key?("__type") || value.values.any? { |v| typed_value?(v) }
        when Array then value.any? { |v| typed_value?(v) }
        else false
        end
      end

      # A JSON object field value: a Hash that is not a Parse operator or a
      # typed value (Pointer, Date, File, GeoPoint, ...).
      # @!visibility private
      def plain_sub_document?(value)
        value.is_a?(Hash) && !value.key?("__op") && !value.key?("__type")
      end

      # Diff the handler's object against a fresh build of the same payload.
      #
      # Only fields that are dirty on either object can differ: a field the
      # client did not write and the handler did not touch is clean on both.
      # Comparing just those keeps the getters off fields the payload never
      # carried (which would otherwise autofetch).
      #
      # @return [Array(Hash, Array<String>)] the changed wire fields with their
      #   encoded values, and the wire fields to drop from the write because
      #   the handler returned them to their stored value.
      # @!visibility private
      def handler_field_changes(payload, obj, raw_original)
        fresh = payload.unmemoized_parse_object
        fresh = nil unless fresh.instance_of?(obj.class)
        candidates = obj.changed.map(&:to_sym)
        candidates |= fresh.changed.map(&:to_sym) if fresh
        candidates &= snapshot_fields(obj)
        after = wire_values(obj, candidates)
        before = fresh ? wire_values(fresh, candidates) : {}

        changes = {}
        drops = []
        after.each do |remote, value|
          next if before.key?(remote) && before[remote] == value
          if raw_original
            stored = raw_original.key?(remote) ? raw_original[remote].as_json : nil
            unchanged = raw_original.key?(remote) ? stored == value : (value.is_a?(Hash) && value["__op"] == "Delete")
            if unchanged
              drops << remote
              next
            end
          end
          changes[remote] = value
        end

        # Relation edits are tracked on the proxies, not as field values. A
        # relation field whose pending operation differs from the client's
        # was changed by the handler or reverted by a field guard: write the
        # handler's operation, or drop the client's when none is left.
        ops_after = relation_ops(obj)
        ops_before = fresh ? relation_ops(fresh) : {}
        (ops_after.keys | ops_before.keys).each do |remote|
          next if ops_after[remote] == ops_before[remote]
          if ops_after.key?(remote)
            changes[remote] = ops_after[remote]
          else
            drops << remote
          end
        end
        [changes, drops]
      end

      # Pending relation operations of an object, keyed by remote field.
      # Additions win over removals for the same field, matching
      # `changes_payload`.
      # @!visibility private
      def relation_ops(obj)
        return {} unless obj.respond_to?(:relation_changes?) && obj.relation_changes?
        additions, removals = obj.relation_change_operations.as_json
        (removals || {}).merge(additions || {})
      end

      # Declared, non-base, non-relation fields of an object.
      # @!visibility private
      def snapshot_fields(obj)
        klass = obj.class
        return [] unless klass.respond_to?(:fields)
        klass.fields.reject do |name, type|
          Parse::Properties::BASE_KEYS.include?(name.to_sym) || type == :relation
        end.keys.map(&:to_sym)
      end

      # Encode the given fields of an object in Parse wire form, keyed by
      # remote field name, using the same encoder the SDK uses for a save
      # (`attribute_updates`). A nil value encodes as a Delete operator.
      # Autofetch is suspended so reading a field never reaches the network.
      # @!visibility private
      def wire_values(obj, fields)
        return {} if fields.empty?
        names = fields.map(&:to_s).freeze
        prior_autofetch = obj.instance_variable_get(:@_autofetch_disabled)
        obj.instance_variable_set(:@_autofetch_disabled, true)
        obj.define_singleton_method(:changed) { names }
        begin
          obj.attribute_updates.as_json
        ensure
          singleton = obj.singleton_class
          singleton.send(:remove_method, :changed) if singleton.method_defined?(:changed, false)
          obj.instance_variable_set(:@_autofetch_disabled, prior_autofetch)
        end
      end

      # Resolve an afterFind handler result.
      #
      # Parse Server's afterFind handling maps each returned row through
      # `toJSONwithObjects`, which turns any plain JSON object (everything an
      # HTTP webhook can send) into `{}`, and crashes on a non-array body. A
      # missing result keeps the matched rows. So an HTTP afterFind can observe
      # the rows or deny the query, but it cannot rewrite them. The reply is
      # always `nil` (sent as `{}`, with no `success` key), and a handler that tries
      # to drop or add rows is refused with an error rather than having the
      # rows it meant to hide returned anyway.
      #
      # @param payload [Parse::Webhooks::Payload] the afterFind payload.
      # @param result [Object] the handler's return value.
      # @return [nil]
      # @raise [Parse::Webhooks::ResponseError] when the handler returned
      #   `false` or a different set of rows.
      # @!visibility private
      def after_find_reply!(payload, result)
        if result == false
          raise Parse::Webhooks::ResponseError, "afterFind rejected by webhook handler"
        end
        if result.is_a?(Array) && payload
          returned = result.map { |row| after_find_row_id(row) }
          matched = Array(payload.objects).map { |row| after_find_row_id(row) }
          unless returned.size == matched.size && returned.sort_by(&:to_s) == matched.sort_by(&:to_s)
            warn "[Parse::Webhooks] an afterFind handler for " \
                 "#{Parse::TerminalSafe.sanitize_line(payload.parse_class)} returned a different " \
                 "set of rows. Parse Server cannot apply row changes from an HTTP afterFind " \
                 "webhook, so the find is denied instead. Filter in beforeFind, or deny with error!."
            raise Parse::Webhooks::ResponseError,
                  "afterFind webhooks cannot filter or replace results"
          end
        end
        nil
      end

      # @!visibility private
      def after_find_row_id(row)
        case row
        when Hash then row["objectId"] || row[:objectId] || row["id"] || row[:id]
        else row.respond_to?(:id) ? row.id : row
        end
      end

      # The value sent as `success` for a routed (or unrouted) trigger result.
      # `nil` for beforeSave / afterFind means "pass through": the Rack app
      # then replies `{}` (see {PASS_THROUGH_BODY}).
      #
      # @param payload [Parse::Webhooks::Payload] the request payload.
      # @param result [Object] the dispatch result.
      # @return [Object] the success value.
      # @!visibility private
      def trigger_success_value(payload, result)
        # beforeSave: nil means "keep the write as sent", a Hash replaces it.
        return (result.is_a?(Hash) ? result : nil) if payload.before_save?
        # afterFind: only "no result" is safe (keeps the rows); see after_find_reply!.
        return nil if payload.after_find?
        result.nil? ? true : result
      end

      # Whether a dispatch result should be sent as {PASS_THROUGH_BODY}.
      # @!visibility private
      def pass_through_reply?(payload, result)
        result.nil? && payload.respond_to?(:trigger?) && payload.trigger? &&
          (payload.before_save? || payload.after_find?)
      end

      # Generates a success response for Parse Server.
      # @param data [Object] the data to send back with the success.
      # @return [Hash] a success data payload
      def success(data = true)
        { success: data }.to_json
      end

      # Generates an error response for Parse Server.
      # @param data [Object] the data to send back with the error.
      # @param code [Integer, nil] an optional Parse error code to include.
      # @return [Hash] a error data payload
      def error(data = false, code = nil)
        body = { error: data }
        body[:code] = code unless code.nil?
        body.to_json
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
      # (e.g. `host.docker.internal`) which only resolve from inside the
      # Parse Server container. May also be enabled via
      # `PARSE_WEBHOOK_ALLOW_PRIVATE_URLS=true`. Do not enable in
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

      # Extract the Parse class name from a webhook request path. Parse Server
      # registers each trigger at `<endpoint>/<triggerName>/<className>`
      # (functions at `<endpoint>/<functionName>`), so for a trigger the class
      # is the last segment and the second-to-last is a known trigger name.
      # Returns nil for a function path, a path with no recognizable trigger
      # segment, or a className that fails the conservative charset check
      # (Parse class names are `[A-Za-z0-9_]`, built-ins prefixed with `_`).
      # The charset gate keeps an attacker-supplied path (reachable when
      # `allow_unauthenticated` is set) from injecting an arbitrary routing /
      # scrub key.
      #
      # @param path [String] the request PATH_INFO.
      # @return [String, nil] the sanitized class name, or nil.
      def trigger_class_from_path(path)
        segments = path.to_s.split("/").reject(&:empty?)
        return nil if segments.size < 2
        trigger, klass = segments[-2], segments[-1]
        # register_triggers! builds the URL with the LOCAL snake_case trigger
        # name (`after_find`), while Parse Server sends the camelCase form in the
        # body — accept both so the path segment is recognized either way.
        known = (Parse::API::Hooks::TRIGGER_NAMES + Parse::API::Hooks::TRIGGER_NAMES_LOCAL).map(&:to_s)
        return nil unless known.include?(trigger)
        # Allow a leading `@` for the Parse pseudo-classes (`@Connect` for the
        # connection-global LiveQuery trigger, `@File` for file triggers): the
        # SDK encodes the className in the per-trigger URL, so beforeConnect
        # would not route without it. Mirrors the trigger-className validator
        # (Parse::API::PathSegment.trigger_class_name!). Still anchored and
        # charset-limited -- this gate keeps an attacker-supplied path (reachable
        # only under allow_unauthenticated) from injecting an arbitrary routing
        # / scrub key.
        return nil unless /\A@?_?[A-Za-z][A-Za-z0-9_]*\z/.match?(klass)
        klass
      end

      # @!visibility private
      def call!(env)
        request = Rack::Request.new env
        response = Rack::Response.new

        # Whether this request proved it came from Parse Server: the webhook
        # key matched, or (below) a configured signature verified. Without
        # either, the body's `master` flag is only a claim.
        authenticated = false
        if self.key.present?
          authenticated = true
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
        replay_error, signature_verified = ReplayProtection.check(
          request.env,
          body_str,
          request.env["HTTP_X_PARSE_REQUEST_ID"]
        )
        if replay_error
          response.write error(replay_error)
          return response.finish
        end
        # Uses the result of the check that just ran, not a second read of
        # the signing secret, so a secret changed mid-request cannot mark an
        # unverified request as authenticated.
        authenticated ||= signature_verified

        # Parse Server registers each trigger at
        # `<endpoint>/<triggerName>/<className>`. For beforeFind/afterFind the
        # payload body carries NO className anywhere, so the request PATH is the
        # only authoritative source of the class — without it, find triggers
        # don't route (parse_class is nil) and afterFind `objects` can't have
        # their :vector columns stripped. Thread it into the payload here, before
        # construction, so it is available for both routing and the scrub. Nil
        # for function requests and for malformed paths.
        webhook_class = Parse::Webhooks.trigger_class_from_path(request.path)
        begin
          payload = Parse::Webhooks::Payload.new(body_str, webhook_class)
          payload.authenticated = authenticated
        rescue => e
          warn "Invalid webhook payload format: #{Parse::TerminalSafe.sanitize_line(e.to_s)}"
          response.write error("Invalid payload format. Should be valid JSON.")
          return response.finish
        end

        # A trigger whose body names a different class than the one the
        # request was routed to (the URL path) is forged or misrouted. Refuse
        # it before any handler runs or any typed object is built from it.
        if payload.trigger? && payload.payload_class_mismatch?
          response.write error("Webhook payload class does not match the trigger class.")
          return response.finish
        end

        if self.logging.present?
          # Everything interpolated below arrives in the webhook request body:
          # the trigger/function names, the object id, and the whole payload are
          # caller-controlled, and these lines go to the app server's console.
          # Escape control sequences so a stored value cannot drive the terminal
          # of whoever is tailing the log.
          if payload.trigger?
            puts "[Webhooks::Request] --> #{Parse::TerminalSafe.sanitize_line(payload.trigger_name)} " \
                 "#{Parse::TerminalSafe.sanitize_line(payload.parse_class)}:" \
                 "#{Parse::TerminalSafe.sanitize_line(payload.parse_id)}"
          elsif payload.function?
            puts "[ParseWebhooks Request] --> Function #{Parse::TerminalSafe.sanitize_line(payload.function_name)}"
          end
          if self.logging == :debug
            puts "[Webhooks::Payload] ----------------------------"
            puts Parse::TerminalSafe.sanitize(
              Parse::Middleware::BodyBuilder.redact(payload.as_json.to_json)
            )
            puts "----------------------------------------------------\n"
          end
        end

        begin
          result = true
          if payload.function? && payload.function_name.present?
            # An unknown function must fail. Answering success would tell the
            # caller that a function ran when nothing did.
            unless Parse::Webhooks.route_registered?(:function, payload.function_name)
              raise Parse::Webhooks::ResponseError,
                    "Webhook function #{payload.function_name} is not registered."
            end
            result = Parse::Webhooks.call_route(:function, payload.function_name, payload)
            result = true if result.nil?
          elsif payload.trigger? && payload.parse_class.present? && payload.trigger_name.present?
            # call hooks subscribed to the specific class
            result = Parse::Webhooks.call_route(payload.trigger_name, payload.parse_class, payload)

            # call hooks subscribed to any class route
            generic_result = Parse::Webhooks.call_route(payload.trigger_name, "*", payload)
            result = generic_result if generic_result.present? && result.nil?

            # Fire the chained ActiveModel after_save/after_create (or
            # after_destroy) callbacks exactly once per delivery -- after BOTH
            # route calls above -- so an app that registers both a class route
            # and a `"*"` route doesn't double-fire them. Each is a no-op for
            # every other trigger.
            Parse::Webhooks.run_after_save_chain(payload)
            Parse::Webhooks.run_after_delete_chain(payload)

            # An unrouted trigger (or a handler that returned nil) passes the
            # operation through unchanged, in the shape each trigger needs.
            result = Parse::Webhooks.trigger_success_value(payload, result)
          elsif payload.trigger?
            # A trigger the router cannot attribute to a class: pass it through
            # unchanged rather than failing the client's operation.
            if self.logging.present?
              puts "[Webhooks] --> Could not find mapping route for " \
                "#{Parse::TerminalSafe.sanitize_line(Parse::Middleware::BodyBuilder.redact(payload.to_json))}"
            end
            result = Parse::Webhooks.trigger_success_value(payload, nil)
          else
            if self.logging.present?
              puts "[Webhooks] --> Could not find mapping route for " \
                "#{Parse::TerminalSafe.sanitize_line(Parse::Middleware::BodyBuilder.redact(payload.to_json))}"
            end
            raise Parse::Webhooks::ResponseError, "Unrecognized webhook request."
          end

          body = pass_through_reply?(payload, result) ? PASS_THROUGH_BODY : success(result)
          if self.logging.present?
            # The reply can echo the client's write (passwords, auth data,
            # tokens a handler returned), so it is redacted like the request.
            puts "[Webhooks::Response] ----------------------------"
            puts Parse::TerminalSafe.sanitize(Parse::Middleware::BodyBuilder.redact(body))
            puts "----------------------------------------------------\n"
          end
          response.write body
          # Schedule any after_response work to run once this reply is flushed,
          # off the client's critical path. Registered on the success path so the
          # deferred work overlaps a response Parse Server will act on.
          dispatch_deferred(env, payload)
          return response.finish
        rescue Parse::Webhooks::ResponseError, ActiveModel::ValidationError => e
          if payload.trigger?
            puts "[Webhooks::ResponseError] >> #{Parse::TerminalSafe.sanitize_line(payload.trigger_name)} " \
                 "#{Parse::TerminalSafe.sanitize_line(payload.parse_class)}:" \
                 "#{Parse::TerminalSafe.sanitize_line(payload.parse_id)}: " \
                 "#{Parse::TerminalSafe.sanitize_line(e.to_s)}"
          elsif payload.function?
            puts "[Webhooks::ResponseError] >> #{Parse::TerminalSafe.sanitize_line(payload.function_name)}: " \
                 "#{Parse::TerminalSafe.sanitize_line(e.to_s)}"
          end
          code = e.respond_to?(:code) ? e.code : nil
          response.write error(e.to_s, code)
          return response.finish
        rescue StandardError => e
          # Anything else a handler (or the router) raised. Answer with a JSON
          # error so Parse Server denies the operation cleanly, and keep the
          # exception message out of the reply: it can quote record data or
          # internals. The log line carries the class and a redacted message.
          where = payload.trigger? ? "#{payload.trigger_name} #{payload.parse_class}" : payload.function_name
          warn "[Webhooks::Error] >> #{Parse::TerminalSafe.sanitize_line(where.to_s)}: #{e.class}: " \
               "#{Parse::TerminalSafe.sanitize_line(Parse::Middleware::BodyBuilder.redact(e.message.to_s))}"
          response = Rack::Response.new
          response.write error("Webhook handler failed.")
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
