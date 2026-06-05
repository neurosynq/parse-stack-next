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
                     triggerName: nil,
                     event: nil, clients: nil, subscriptions: nil,
                     context: nil }.freeze
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
      # @!attribute [rw] event
      #   The LiveQuery event type for an +afterEvent+ trigger -- one of
      #   +"create"+, +"enter"+, +"update"+, +"leave"+, or +"delete"+ -- or
      #   +"connect"+ for a +beforeConnect+ trigger. +nil+ for every non-
      #   LiveQuery trigger. See {#after_event?} / {#before_connect?}.
      #   @return [String, nil]
      # @!attribute [rw] clients
      #   Connection-global metadata sent on the LiveQuery +beforeConnect+ /
      #   +afterEvent+ triggers: the number of currently-connected LiveQuery
      #   clients. +nil+ for non-LiveQuery triggers.
      #   @return [Integer, nil]
      # @!attribute [rw] subscriptions
      #   Connection-global metadata sent on the LiveQuery +beforeConnect+ /
      #   +afterEvent+ triggers: the number of active subscriptions. +nil+ for
      #   non-LiveQuery triggers.
      #   @return [Integer, nil]
      attr_accessor :event, :clients, :subscriptions
      # @!attribute [rw] context
      #   The caller-supplied context object threaded from the originating REST
      #   write or cloud-function call via the +X-Parse-Cloud-Context+ header.
      #   Parse Server includes this as a top-level +context+ key in trigger
      #   payloads (beforeSave/afterSave/etc.). Returns a Hash when present, or
      #   +nil+ when the originating request carried no context.
      #   @return [Hash, nil]
      attr_accessor :context
      # @!attribute [r] session_token
      #   The caller's live Parse session token, captured from the incoming
      #   webhook payload (`user.sessionToken`) before credentials are scrubbed
      #   from {#user} / {#object} / {#original} / {#update}. Present only when
      #   the originating request was made by a logged-in user -- a master-key
      #   request carries no user and no token, so this is +nil+. It is
      #   intentionally NOT one of {ATTRIBUTES}, so it never appears in
      #   {#as_json} or in the redacted request log. Reach for it (or the
      #   higher-level {#user_client} / {#user_agent}) only when a handler
      #   deliberately wants to act on the server as the calling user.
      #   @return [String, nil]
      attr_reader :session_token
      # @!visibility private
      attr_accessor :webhook_class
      alias_method :installationId, :installation_id
      alias_method :functionName, :function_name
      alias_method :triggerName, :trigger_name

      # You would normally never create a {Parse::Webhooks::Payload} object since it is automatically
      # provided to you when using Parse::Webhooks.
      # @see Parse::Webhooks
      # @param hash [String, Hash] the raw webhook body (JSON string or Hash).
      # @param webhook_class [String, nil] the Parse class name derived from the
      #   webhook URL path (`<endpoint>/<triggerName>/<className>`). This is the
      #   ONLY authoritative source of the class for beforeFind/afterFind
      #   triggers — Parse Server omits `className` from the find payload body
      #   entirely (the matched `objects` carry no `className` and there is no
      #   top-level one). Threading it here lets `parse_class` resolve (so find
      #   triggers route) and lets `:vector` columns be stripped from afterFind
      #   `objects`. For save/delete triggers the path className equals the
      #   body's, so it is consistent; for functions it is nil.
      def initialize(hash = {}, webhook_class = nil)
        hash = JSON.parse(hash, max_nesting: 20) if hash.is_a?(String)
        hash = Hash[hash.map { |k, v| [k.to_s.underscore.to_sym, v] }]
        @raw = hash
        # Set BEFORE the vector scrub below so the route-derived class is
        # available to strip :vector columns from afterFind objects (whose
        # body carries no className of its own).
        @webhook_class = webhook_class.to_s if webhook_class && !webhook_class.to_s.empty?
        @master = hash[:master]
        # Capture the caller's session token from the *unscrubbed* user hash
        # before scrub_credentials strips it below. Parse Server includes
        # `user.sessionToken` on every trigger fired by a logged-in caller
        # (it is absent for master-key-originated requests). Pulling it aside
        # here -- rather than leaving it in @user -- keeps it out of any object
        # a handler might persist and out of #as_json / the request log, while
        # still letting a handler opt in to acting as the calling user via
        # #session_token / #user_client / #user_agent.
        @session_token = self.class.extract_session_token(hash[:user])
        # LiveQuery beforeConnect/beforeSubscribe carry the caller's session
        # token at the TOP LEVEL (not nested under `user`), because no user is
        # resolved yet when the trigger fires. Capture it here -- with the same
        # "set it aside, keep it out of as_json / the log" treatment as the
        # nested form -- so #user_client / #user_agent can act as the caller.
        # It is intentionally NOT one of ATTRIBUTES.
        if @session_token.nil?
          top_token = hash[:session_token].to_s.strip
          @session_token = top_token unless top_token.empty?
        end
        # Webhook trigger payloads (beforeSave/afterSave/etc.) are delivered by
        # Parse Server and, when a webhook key is configured (the default; see
        # Parse::Webhooks.allow_unauthenticated for the opt-out used in tests /
        # local dev), authenticated by it -- so they are treated as trusted,
        # server-authoritative state. A handler is meant to receive the full
        # object -- createdAt/updatedAt, ACL, internal fields and all. The only
        # thing stripped here is genuine credential material a handler never
        # legitimately needs to read inline (live session tokens -- captured
        # above for opt-in user-scoped clients first -- and offline-crackable
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
        @trigger_name = hash[:trigger_name]
        # Resolve the model class once so :vector columns can be stripped from
        # every object-shaped payload (see scrub_vector_columns). Credentials
        # are scrubbed first, then vectors. The route-derived @webhook_class is
        # authoritative and preferred — it is the only class source for
        # afterFind (whose body carries no className anywhere); for save/delete
        # it equals the body's className. Falls back to the object/original
        # className for older callers that don't supply a route class.
        vec_klass = self.class.resolve_klass_by_name(@webhook_class) ||
                    self.class.resolve_vector_klass(hash[:object], hash[:original])
        @object = self.class.scrub_vector_columns(self.class.scrub_credentials(hash[:object]), vec_klass)
        @original = self.class.scrub_vector_columns(self.class.scrub_credentials(hash[:original]), vec_klass)
        @update = self.class.scrub_vector_columns(self.class.scrub_credentials(hash[:update]), vec_klass) || {}
        # Added for beforeFind and afterFind triggers. afterFind objects are all
        # of one class but carry no className of their own, so the route-derived
        # vec_klass is the only way to strip their :vector columns.
        @query = hash[:query]
        # LiveQuery connection metadata. `event` is the afterEvent event type
        # (create/enter/update/leave/delete) or "connect" for beforeConnect;
        # `clients`/`subscriptions` are connection-global counts. All nil for
        # the object / auth triggers. These are plain scalars (no credential
        # material), so they pass through unscrubbed.
        @event = hash[:event]
        @clients = hash[:clients]
        @subscriptions = hash[:subscriptions]
        @objects = Array(hash[:objects]).map do |o|
          self.class.scrub_vector_columns(self.class.scrub_credentials(o), vec_klass)
        end
        @log = hash[:log]
        # Caller-supplied context object threaded via X-Parse-Cloud-Context.
        # This is caller metadata (not a credential), so it passes through
        # without scrubbing — mirroring the treatment of @query and @log.
        @context = hash[:context]
        # Blocks registered by a handler via #after_response / #defer, to run
        # after the webhook response has been sent (drained by the Rack app).
        @deferred_callbacks = []
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

      # @!visibility private
      # Resolve the Parse::Object subclass for a webhook payload from the
      # `className` of the first object-shaped hash given. Returns nil when
      # no class name is present or no matching model is registered (the
      # caller then skips vector stripping — fail-open is acceptable here:
      # an unregistered class has no declared `:vector` columns to strip).
      def self.resolve_vector_klass(*candidates)
        candidates.each do |obj|
          next unless obj.is_a?(Hash)
          name = obj["className"] || obj[:className]
          next if name.nil? || name.to_s.empty?
          klass = resolve_klass_by_name(name)
          return klass if klass
        end
        nil
      end

      # @!visibility private
      # Resolve a registered Parse::Object subclass from a bare class-name
      # string (e.g. the route-derived @webhook_class). Returns nil for a blank
      # name or an unregistered class (the caller then skips vector stripping —
      # fail-open, as an unregistered class has no declared :vector columns).
      def self.resolve_klass_by_name(name)
        return nil if name.nil? || name.to_s.empty?
        klass = (Parse::Object.find_class(name.to_s) rescue nil)
        klass.respond_to?(:fields) ? klass : nil
      end

      # @!visibility private
      # Returns a copy of +obj+ with the model's declared `:vector`
      # columns removed. Embeddings are large dense float arrays that leak
      # ML signal; a webhook handler has no reason to receive them, and
      # leaving them in bloats logs and any object a handler re-persists.
      # Mirrors the `as_json` default (vectors omitted) — a class that opts
      # into `vector_visibility :public` keeps its vectors here too.
      #
      # `klass` may be passed explicitly (so changed-only payloads like
      # `update`, which carry no `className`, are still scrubbed using the
      # class resolved from the sibling `object`/`original` hash); when nil
      # it is resolved from the hash's own `className`.
      # Pass-through for non-Hash input (and nil).
      def self.scrub_vector_columns(obj, klass = nil)
        return obj unless obj.is_a?(Hash)
        klass ||= resolve_vector_klass(obj)
        return obj if klass.nil?
        if klass.respond_to?(:vectors_public_by_default?) && klass.vectors_public_by_default?
          return obj
        end
        vector_fields = klass.fields(:vector).keys.map(&:to_s)
        return obj if vector_fields.empty?
        field_map = klass.respond_to?(:field_map) ? klass.field_map : {}
        wire = vector_fields.map { |f| (field_map[f.to_sym] || f).to_s }
        denied = (vector_fields + wire)
        obj.reject { |k, _| denied.include?(k.to_s) }
      end

      # @!visibility private
      # Pulls the caller's session token out of the (unscrubbed) +user+ hash.
      # Parse Server sends it as the camelCase string key +sessionToken+; this
      # tolerates a symbol key and the snake_case form too, mirroring the
      # leniency in +scrub_credentials+. Returns +nil+ for a blank token or a
      # non-Hash / absent user (a master-key request has no user).
      def self.extract_session_token(user_hash)
        return nil unless user_hash.is_a?(Hash)
        token = user_hash["sessionToken"] || user_hash[:sessionToken] ||
                user_hash["session_token"] || user_hash[:session_token]
        token = token.to_s.strip
        token.empty? ? nil : token
      end

      # @return [ATTRIBUTES]
      def attributes
        ATTRIBUTES
      end

      # Redacted inspection. The default Ruby `#inspect` would dump every ivar,
      # including the captured `@session_token` and the *pre-scrub* `@raw` hash
      # (which still holds the caller's sessionToken and any password hashes).
      # That is exactly the surface an error reporter or a stray `p payload`
      # hits, so show only non-sensitive routing fields and a boolean for the
      # token's presence. Use #as_json / the individual accessors for the
      # (already credential-scrubbed) object data.
      def inspect
        "#<#{self.class.name} trigger=#{@trigger_name.inspect} " \
        "function=#{@function_name.inspect} class=#{parse_class.inspect} " \
        "id=#{parse_id.inspect} master=#{@master ? true : false} " \
        "session_token=#{@session_token ? "[FILTERED]" : "nil"}>"
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

      # true if this payload carried a caller session token -- i.e. the
      # originating request was made by a logged-in user rather than the
      # master key, so {#user_client} / {#user_agent} can act as that user.
      # @return [Boolean]
      def session_token?
        !@session_token.nil?
      end

      # An opt-in, user-scoped {Parse::Client} for acting on the server as the
      # webhook's calling user. It mirrors the default client's connection
      # settings (+server_url+, +application_id+, +api_key+) but carries NO
      # master key and BINDS the caller's {#session_token}, so every request it
      # makes -- with no further ceremony -- is authorized by Parse Server as
      # that user: ACL, CLP and +protectedFields+ are all enforced. (A
      # `Parse.with_session` block still overrides the bound token if you need
      # to act as someone else within a call.) Memoized per payload, since each
      # webhook delivery carries a distinct token.
      # @return [Parse::Client, nil] +nil+ when the payload carried no token.
      def user_client
        return nil if @session_token.nil?
        @user_client ||= Parse::Client.client.become(@session_token)
      end

      # An opt-in, non-master {Parse::Agent} scoped to the webhook caller's
      # session token. Because its client has no master key and it is built
      # with a non-empty +session_token:+, the agent runs in CLIENT MODE:
      # every tool/query routes through a path Parse Server (or the SDK's own
      # ACL/CLP enforcement layer) authorizes as the calling user, with no
      # master-key fallback to silently bypass row-level security. This is the
      # handle to use when a handler should read or act strictly within the
      # caller's permissions. Additional agent options (e.g.
      # +permissions: :readwrite+) may be passed through.
      # @param opts [Hash] extra keyword args forwarded to {Parse::Agent#initialize}.
      # @return [Parse::Agent, nil] +nil+ when the payload carried no token.
      def user_agent(**opts)
        return nil if @session_token.nil?
        require_relative "../agent" unless defined?(Parse::Agent)
        # Strip the two identity kwargs from the passthrough: a Ruby double-splat
        # that repeats an explicit keyword WINS, so user_agent(client: master)
        # or user_agent(session_token: other) would otherwise silently defeat the
        # whole point (scoping to the caller). The scoping is non-negotiable here.
        opts = opts.except(:session_token, :client)
        Parse::Agent.new(session_token: @session_token, client: user_client, **opts)
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

      # true if this is a beforeLogin webhook trigger request.
      #
      # NOTE: a +beforeLogin+ payload carries the user being authenticated as
      # {#object} / {#parse_object} (a +_User+), NOT as {#user} -- the caller is
      # not yet authenticated when the trigger fires, so {#user} is +nil+. (By
      # +afterLogin+ both are populated and equal.) Reach for {#parse_object} to
      # inspect the logging-in user during +beforeLogin+.
      def before_login?
        trigger? && @trigger_name.to_sym == :beforeLogin
      end

      # true if this is a afterLogin webhook trigger request.
      def after_login?
        trigger? && @trigger_name.to_sym == :afterLogin
      end

      # true if this is a afterLogout webhook trigger request. The logged-out
      # session is carried as {#object} / {#parse_object} (a +_Session+).
      def after_logout?
        trigger? && @trigger_name.to_sym == :afterLogout
      end

      # true if this is a beforePasswordResetRequest webhook trigger request.
      # The target user is carried as {#object} / {#parse_object} (a +_User+).
      def before_password_reset_request?
        trigger? && @trigger_name.to_sym == :beforePasswordResetRequest
      end

      # true if this is a LiveQuery beforeConnect webhook trigger request.
      # Connection-global: carries no {#object}; the className is the +@Connect+
      # sentinel and the caller's token (if any) is in {#session_token}.
      def before_connect?
        trigger? && @trigger_name.to_sym == :beforeConnect
      end

      # true if this is a LiveQuery beforeSubscribe webhook trigger request.
      # Shaped like beforeFind: carries a {#query} (see {#parse_query}) and the
      # className comes from the request path, not the body.
      def before_subscribe?
        trigger? && @trigger_name.to_sym == :beforeSubscribe
      end

      # true if this is a LiveQuery afterEvent webhook trigger request. The
      # event type (create/enter/update/leave/delete) is in {#event}.
      def after_event?
        trigger? && @trigger_name.to_sym == :afterEvent
      end

      # true if this is one of the authentication-side triggers
      # (beforeLogin / afterLogin / afterLogout / beforePasswordResetRequest).
      # These carry a +_User+ / +_Session+ as {#object} but are NOT object
      # save/delete triggers: no ActiveModel save/create/destroy callbacks run
      # for them, and Parse Server ignores the response body (the only way to
      # affect a +before*+ one is to deny it -- see the webhook router).
      def auth_trigger?
        before_login? || after_login? || after_logout? || before_password_reset_request?
      end

      # true if this is one of the LiveQuery triggers (beforeConnect /
      # beforeSubscribe / afterEvent). Parse Server delivers these over an HTTP
      # webhook only in a co-located single-process LiveQuery setup;
      # +beforeConnect+ in particular carries a live client and is effectively
      # in-process-only. See the webhooks guide.
      def live_query_trigger?
        before_connect? || before_subscribe? || after_event?
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

        # afterSave on a CREATE: there is no prior persisted state, so every
        # populated data field is new. Build symmetry with the UPDATE path above
        # by seeding the identity / system fields (objectId, timestamps, ACL,
        # className, plus the credential / permission keys) into a pristine
        # object, then overlaying the full object with dirty tracking. Because
        # the overlay's protected_set is exactly the seed key set, the system
        # fields come ONLY from the clean seed and the overlay touches ONLY
        # declared data properties (nil -> value -> changed) -- so `*_changed?`
        # reports every field the create populated while createdAt / updatedAt /
        # ACL stay clean. This lets handlers key off dirty tracking uniformly
        # across create and update (e.g. building a sync payload from changed
        # fields). Credentials / _rperm / _wperm / authData / roles are filtered
        # from the overlay (seeded read-only, never marked changed), and an
        # after-trigger response is only true/false, so nothing here can persist
        # a forged field.
        if after_save? && @object.is_a?(Hash)
          seed_keys = Parse::Properties::PROTECTED_INITIALIZE_KEYS +
                      %w[objectId createdAt updatedAt ACL className __type]
          seed = @object.slice(*seed_keys)
          o = Parse::Object.build seed, parse_class
          # `build` applies declared `default:` values onto the seed and then
          # clears changes, baking each default into the "pristine" baseline.
          # Without correction, the overlay's dirty guard (`unless val ==
          # current`) would SUPPRESS marking any create value equal to its
          # default (e.g. status: "draft", count: 0, archived: false), silently
          # defeating this branch's whole purpose. Reset the default-bearing
          # ivars to nil for the fields the overlay is about to set, then
          # re-clear, so the overlay's guard sees a differing current ivar and
          # marks every populated data field changed. (`*_changed?` / `changes`
          # / `changed` then report the field; for a defaulted field the
          # reported prior value is the default rather than nil, since the
          # getter re-derives the default — its prior *effective* value.)
          # `defaults_list` never contains the seeded system fields
          # (objectId/createdAt/updatedAt/ACL), so this cannot disturb them;
          # defaults for fields ABSENT from the payload are left intact so their
          # value still reads through.
          fmap = o.class.respond_to?(:field_map) ? o.class.field_map : {}
          o.class.defaults_list.each do |k|
            wire = (fmap[k] || k).to_s
            next unless @object.key?(wire) || @object.key?(k.to_s)
            o.instance_variable_set(:"@#{k}", nil)
          end
          o.clear_changes!
          o.apply_attributes! @object, dirty_track: true, protected_set: seed_keys
          return o
        end

        # Every other trigger (afterDelete, afterFind, and any before* path that
        # did not match above): the full object as the server sent it.
        # createdAt/updatedAt survive (only credentials are scrubbed), so
        # `new?` / `existed?` read correctly.
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

      # Register a block to run **after** this webhook's response has been sent
      # to Parse Server, off the client's critical path. Use it to do work that
      # should not add latency to the save/function the client is waiting on —
      # search indexing, cache warming, fan-out notifications.
      #
      # The handler still returns its value synchronously (the response Parse
      # Server acts on); the deferred block runs afterward. When the SDK is
      # mounted under a server that supports `rack.after_reply` (Puma, Unicorn)
      # the block runs once the response is flushed to the socket, on the same
      # worker thread; otherwise it runs in a detached thread. Each block is
      # isolated, so one raising neither affects the response nor the others.
      #
      #   Parse::Webhooks.route :after_save, :Post do
      #     post = parse_object
      #     after_response { SearchIndex.reindex(post.id) }
      #     post
      #   end
      #
      # `self` inside the block is this payload (it closes over the handler's
      # scope), so `parse_object`, `params`, etc. remain available. Note the
      # block runs in-process and does not survive a worker restart — for work
      # that *must* happen, hand it to a durable job queue instead. Deferred
      # callbacks fire only when the payload is processed through the mounted
      # `Parse::Webhooks` Rack app.
      #
      # @yield the work to run after the response is sent.
      # @return [Boolean] true if a block was registered.
      def after_response(&block)
        return false unless block_given?
        @deferred_callbacks ||= []
        @deferred_callbacks << block
        true
      end
      alias_method :defer, :after_response

      # @!visibility private
      # The blocks registered via {#after_response}; drained by the Rack app
      # ({Parse::Webhooks.dispatch_deferred}) after the response is finished.
      # @return [Array<Proc>]
      def deferred_callbacks
        @deferred_callbacks ||= []
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
