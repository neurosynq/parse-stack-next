# encoding: UTF-8
# frozen_string_literal: true

require "active_model"
require "active_support"
require "active_support/inflector"
require "active_support/core_ext/object"
require "active_support/core_ext/string"
require "active_support/core_ext"
require "active_model/serializers/json"

module Parse
  class Webhooks
    # Represents the data structure that Parse server sends to a registered webhook.
    # Parse Parse allows you to receive Cloud Code webhooks on your own hosted
    # server. The `Parse::Webhooks` class is a lightweight Rack application that
    # routes incoming Cloud Code webhook requests and payloads to locally
    # registered handlers. The payloads are {Parse::Webhooks::Payload} type of objects that
    # represent that data that Parse sends webhook handlers.
    class Payload
      # The set of keys that can be contained in a Parse hash payload for a webhook.
      ATTRIBUTES = { master: nil, user: nil,
                     installationId: nil, params: nil,
                     functionName: nil, object: nil,
                     original: nil, update: nil,
                     query: nil, log: nil,
                     objects: nil,
                     triggerName: nil }.freeze
      include ::ActiveModel::Serializers::JSON
      # @!attribute [rw] master
      #   @return [Boolean] whether the master key was used for this request.
      # @!attribute [rw] user
      #   @return [Parse::User] the user who performed this request or action.
      # @!attribute [rw] installation_id
      #   @return [String] The identifier of the device that submitted the request.
      # @!attribute [rw] params
      #   @return [Hash] The list of function arguments submitted for a function request.
      # @!attribute [rw] function_name
      #   @return [String] the name of the function.
      # @!attribute [rw] object
      #  In a beforeSave, this attribute is the final object that will be persisted.
      #  @return [Hash] the object hash related to a webhook trigger request.
      #  @see #parse_object
      # @!attribute [rw] trigger_name
      #  @return [String] the name of the trigger (ex. beforeSave, afterSave, etc.)
      # @!attribute [rw] original
      #  In a beforeSave, for previously saved objects, this attribute is the Parse::Object
      #  that was previously in the persistent store.
      #  @return [Hash] the object hash related to a webhook trigger request.
      #  @see #parse_object
      # @!attribute [rw] raw
      #   @return [Hash] the raw payload from Parse server.
      # @!attribute [rw] update
      #   @return [Hash] the update payload in the request.
      # @!attribute [r] query
      # The query request in a beforeFind trigger. Available in Parse Server 2.3.1 or later.
      #   @return [Parse::Query]
      # @!attribute [r] objects
      # The set of matching objects in an afterFind trigger. Available in Parse Server 2.3.1 or later.
      #   @return [<Parse::Object>]
      # @!attribute [r] log
      # Logging information if available. Available in Parse Server 2.3.1 or later.
      #   @return [Hash] the set of matching objects in an afterFind trigger.
      attr_accessor :master, :user, :installation_id, :params, :function_name, :object, :trigger_name
      attr_accessor :query, :log, :objects
      attr_accessor :original, :update, :raw
      # @!visibility private
      attr_accessor :webhook_class
      alias_method :installationId, :installation_id
      alias_method :functionName, :function_name
      alias_method :triggerName, :trigger_name

      # You would normally never create a {Parse::Webhooks::Payload} object since it is automatically
      # provided to you when using Parse::Webhooks.
      # @see Parse::Webhooks
      def initialize(hash = {})
        hash = JSON.parse(hash, max_nesting: 20) if hash.is_a?(String)
        hash = Hash[hash.map { |k, v| [k.to_s.underscore.to_sym, v] }]
        @raw = hash
        @master = hash[:master]
        # Webhook trigger payloads (beforeSave/afterSave/etc.) are delivered by
        # Parse Server and, when a webhook key is configured (the default; see
        # Parse::Webhooks.allow_unauthenticated for the opt-out used in tests /
        # local dev), authenticated by it -- so they are treated as trusted,
        # server-authoritative state. A handler is meant to receive the full
        # object -- createdAt/updatedAt, ACL, internal fields and all. The only
        # thing stripped here is genuine credential material a handler never
        # legitimately needs to read (live session tokens, offline-crackable
        # password hashes); see WEBHOOK_TRIGGER_CREDENTIAL_KEYS. Protection
        # against *persisting* forged privileged fields lives on the write path
        # (changes_payload emits only declared, dirty-tracked properties), not on
        # this read path.
        if hash[:user].present?
          # Trusted hydration via .build (not .new) so server-sent timestamps and
          # data fields remain readable; credentials are removed first. Note
          # Parse::User applies its own protections, so `payload.user.auth_data`
          # is not exposed here. The built object is pristine, so a handler that
          # saves payload.user transmits nothing (no dirty changes) and cannot
          # persist forgeries.
          @user = Parse::User.build(self.class.scrub_credentials(hash[:user]))
        end
        @installation_id = hash[:installation_id]
        @params = hash[:params]
        @params = @params.with_indifferent_access if @params.is_a?(Hash)
        @function_name = hash[:function_name]
        @object = self.class.scrub_credentials(hash[:object])
        @trigger_name = hash[:trigger_name]
        @original = self.class.scrub_credentials(hash[:original])
        @update = self.class.scrub_credentials(hash[:update]) || {}
        # Added for beforeFind and afterFind triggers
        @query = hash[:query]
        @objects = hash[:objects] || []
        @log = hash[:log]
      end

      # @!visibility private
      # Genuine credential material that is stripped from every webhook trigger
      # payload before a handler can see it, even though the rest of the
      # (trusted, server-authoritative) payload passes through untouched. A
      # session token is a live bearer credential; a password hash is
      # offline-crackable. A handler has no legitimate reason to read either,
      # and removing them keeps them out of logs and out of any object a handler
      # might persist. Everything else Parse Server sends -- createdAt/updatedAt,
      # ACL, authData, roles, _rperm/_wperm, internal fields -- is preserved so
      # the handler observes the full object. Write-side protection
      # (changes_payload emits only declared, dirty-tracked properties) is what
      # prevents persisting forged privileged fields.
      WEBHOOK_TRIGGER_CREDENTIAL_KEYS = %w[
        sessionToken session_token
        _hashed_password _password_history
      ].freeze

      # @!visibility private
      # Returns a copy of +obj+ with only +WEBHOOK_TRIGGER_CREDENTIAL_KEYS+
      # removed. Operates on string and symbol keys (Parse Server uses camelCase
      # strings on the wire; downstream code may have already symbolized).
      # Pass-through for non-Hash input.
      def self.scrub_credentials(obj)
        return obj unless obj.is_a?(Hash)
        denied = WEBHOOK_TRIGGER_CREDENTIAL_KEYS
        obj.reject do |k, _|
          name = k.to_s
          denied.include?(name) || denied.include?(name.underscore)
        end
      end

      # @return [ATTRIBUTES]
      def attributes
        ATTRIBUTES
      end

      # Method to print to standard that utilizes the an internal id to make it easier
      # to trace incoming requests.
      def wlog(s)
        # generates a unique random number in order to be used in logging. This
        # is useful when debugging issues in production where one server instance
        # may be running multiple threads and you want to trace the incoming call.
        @rid ||= rand(999).to_s.rjust(3)
        puts "[> #{@rid}] #{s}"
        @rid
      end

      # true if this is a webhook function request.
      def function?
        @function_name.present?
      end

      # true if the master key was used for this request.
      def master?
        @master.present?
      end

      # @return [String] the name of the Parse class for this request.
      def parse_class
        return @webhook_class if @webhook_class.present?
        return nil unless @object.present?
        @object[Parse::Model::KEY_CLASS_NAME] || @object[:className]
      end

      # @return [String] the objectId in this request.
      def parse_id
        return nil unless @object.present?
        @object[Parse::Model::OBJECT_ID] || @object[:objectId]
      end

      alias_method :objectId, :parse_id

      # true if this is a webhook trigger request.
      def trigger?
        @trigger_name.present?
      end

      # true if this is a beforeSave or beforeDelete webhook trigger request.
      def before_trigger?
        before_save? || before_delete? || before_find?
      end

      # true if this is a afterSave or afterDelete webhook trigger request.
      def after_trigger?
        after_save? || after_delete? || after_find?
      end

      # true if this is a beforeSave webhook trigger request.
      def before_save?
        trigger? && @trigger_name.to_sym == :beforeSave
      end

      # true if this is a afterSave webhook trigger request.
      def after_save?
        trigger? && @trigger_name.to_sym == :afterSave
      end

      # true if this is a beforeDelete webhook trigger request.
      def before_delete?
        trigger? && @trigger_name.to_sym == :beforeDelete
      end

      # true if this is a afterDelete webhook trigger request.
      def after_delete?
        trigger? && @trigger_name.to_sym == :afterDelete
      end

      # true if this is a beforeFind webhook trigger request.
      def before_find?
        trigger? && @trigger_name.to_sym == :beforeFind
      end

      # true if this is a afterFind webhook trigger request.
      def after_find?
        trigger? && @trigger_name.to_sym == :afterFind
      end

      # true if this request is a trigger that contains an object.
      def object?
        trigger? && @object.present?
      end

      # @return [Parse::Object] a Parse::Object from the original object
      def original_parse_object
        return nil unless @original.is_a?(Hash)
        # Always pass the trigger's expected class explicitly so the
        # className inside the payload cannot redirect this hydration to a
        # different class.
        Parse::Object.build(@original, parse_class)
      end

      # This method returns a Parse::Object by combining the original object, if was provided,
      # with the final object. This will return a dirty tracked Parse::Object subclass,
      # that will have information on which fields have changed between the previous state
      # in the persistent store and the one about to be saved.
      # @param pristine [Boolean] whether the object should be returned without dirty tracking.
      # @return [Parse::Object] a dirty tracked Parse::Object subclass instance
      def parse_object(pristine = false)
        return nil unless object?
        return Parse::Object.build(@object, parse_class) if pristine
        # Memoize so pre-block guard application and the user webhook handler
        # observe the same instance. Otherwise field_guards applied on the
        # framework's pre-built object would be invisible to the block's
        # later parse_object call (which would construct a fresh dirty-tracked
        # object from @object/@original).
        return @parse_object if defined?(@parse_object) && !@parse_object.nil?
        @parse_object = build_parse_object
      end

      # @!visibility private
      # Returns +true+ when +@object+/+@original+ contain a className that
      # disagrees with the trigger's expected class. Used to skip building
      # a typed object when the payload was clearly forged or routed
      # incorrectly.
      def payload_class_mismatch?
        expected = parse_class
        return false if expected.nil?
        [@object, @original, @update].any? do |h|
          h.is_a?(Hash) && h["className"] &&
            !Parse::Model.same_parse_class?(h["className"], expected)
        end
      end

      # Force a fresh build, discarding any memoized parse_object. Used by the
      # webhook framework after mutating @object / @update so a subsequent
      # parse_object call picks up the modified payload state.
      # @!visibility private
      def reset_parse_object_cache!
        @parse_object = nil
      end

      private

      def build_parse_object
        # if its a before trigger, then we build the original object and apply the updates
        # in order to create a Parse::Object that has the dirty tracking information
        # if no original is nil, then it means this is a brand new object, so we create
        # one from the className
        if before_trigger?
          # if original is present, then this is a modified object
          if @original.present? && @original.is_a?(Hash)
            o = Parse::Object.build @original, parse_class
            o.apply_attributes! @object, dirty_track: true
            return o
          else #else the object must be new
            klass = Parse::Object.find_class parse_class
            # if we have a class, return that with updated changes, otherwise
            # default to regular object
            return klass.new(@object || {}) if klass.present?
          end # if we have original
        end # if before_trigger?

        # afterSave on an UPDATE: build the prior state, then overlay the final
        # state with dirty tracking so `*_changed?` / `changes` work inside
        # afterSave handlers (symmetric with the beforeSave path above). The
        # filter uses the timestamp-preserving INITIALIZE key set rather than the
        # wide mass-assignment set: the wide set would strip the incoming
        # `updatedAt` from the overlay, leaving the prior `updatedAt` and breaking
        # `existed?`. The diff still excludes credentials / _rperm / _wperm /
        # authData / roles, and an after-trigger response is only true/false, so
        # there is no path for a forged privileged field to be persisted.
        if after_save? && @original.present? && @original.is_a?(Hash)
          o = Parse::Object.build @original, parse_class
          o.apply_attributes! @object, dirty_track: true,
                                       protected_set: Parse::Properties::PROTECTED_INITIALIZE_KEYS
          return o
        end

        # afterSave on a CREATE (and every other trigger): the full object as the
        # server sent it. createdAt/updatedAt survive (only credentials are
        # scrubbed), so `new?` / `existed?` read correctly.
        Parse::Object.build(@object, parse_class)
      end

      public

      # This method will intentionally raise a {Parse::Webhooks::ResponseError} with
      # a specific message. When used inside of a registered cloud code webhook
      # function or trigger, will halt processing and return the proper error response
      # code back to the Parse server.
      # @param msg [String] the error message to send back.
      # @raise Parse::Webhooks::ResponseError
      # @return [Parse::Webhooks::ResponseError] the raised exception
      def error!(msg = "")
        raise Parse::Webhooks::ResponseError, msg
      end

      # @return [Parse::Query] the Parse query for a beforeFind trigger.
      def parse_query
        return nil unless parse_class.present? && @query.is_a?(Hash)
        Parse::Query.new parse_class, @query
      end

      # Returns true if this webhook was triggered by a Ruby Parse Stack request.
      # This is determined by checking for the '_RB_' prefix in the request ID header.
      # This flag is useful for preventing callback loops and implementing intelligent
      # callback handling based on the request origin.
      # @return [Boolean] true if the request originated from Ruby Parse Stack
      def ruby_initiated?
        @ruby_initiated ||= begin
            request_id = nil

            if @raw.respond_to?(:[])
              # Check for headers at the top level first
              request_id = @raw["x-parse-request-id"] || @raw["X-Parse-Request-Id"] ||
                           @raw[:x_parse_request_id] || @raw[:'X-Parse-Request-Id']

              # If not found at top level, check nested headers
              if request_id.nil?
                headers_sym = @raw[:headers] if @raw[:headers].is_a?(Hash)
                headers_str = @raw["headers"] if @raw["headers"].is_a?(Hash)

                if headers_sym
                  request_id = headers_sym["x-parse-request-id"] || headers_sym["X-Parse-Request-Id"]
                elsif headers_str
                  request_id = headers_str["x-parse-request-id"] || headers_str["X-Parse-Request-Id"]
                end
              end
            end

            request_id&.start_with?("_RB_") || false
          end
      end

      # Returns true if this webhook was triggered by a client request (JavaScript, iOS, Android, etc.)
      # This is the inverse of ruby_initiated? and is useful for callback logic that should
      # only run for client-initiated operations.
      # @return [Boolean] true if the request originated from a client (not Ruby)
      def client_initiated?
        !ruby_initiated?
      end
    end # Payload
  end
end
