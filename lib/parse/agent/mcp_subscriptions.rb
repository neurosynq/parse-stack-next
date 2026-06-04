# encoding: UTF-8
# frozen_string_literal: true

require "json"
require_relative "errors"

module Parse
  class Agent
    # Resource-subscription bridge for the MCP server.
    #
    # MCP 2025-06-18 lets a client `resources/subscribe` to a resource URI and
    # then receive unsolicited `notifications/resources/updated` messages over a
    # server→client channel whenever the underlying data changes. This module
    # bridges that surface onto Parse LiveQuery: a subscribed
    # `parse://<Class>/count` or `parse://<Class>/samples` URI is backed by a
    # LiveQuery subscription on `<Class>`; any matching create/update/delete/
    # enter/leave event is debounced and projected to a single coarse
    # `notifications/resources/updated` for that URI. The client re-reads the
    # resource via `resources/read` to obtain the new value — the SDK never
    # streams row payloads through the MCP resource surface.
    #
    # == Components
    #
    # * {Manager} — per-transport (per {Parse::Agent::MCPRackApp} instance)
    #   coordinator. Owns the session→subscription bookkeeping, derives
    #   LiveQuery credentials from the subscribing agent, starts/stops LiveQuery
    #   subscriptions, and routes debounced updates through the {Notifier}.
    # * {LocalNotifier} — the in-process {Notifier} implementation. A listening
    #   SSE stream registers a delivery callback under its session id; the
    #   bridge publishes notifications to that session id. The {Notifier}
    #   contract is the clustered-ready seam: a Redis-backed implementation can
    #   drop in without touching {Manager} so a LiveQuery event observed on one
    #   worker process can reach a listening stream held on another.
    #
    # == Security: credential derivation (fail-closed)
    #
    # LiveQuery enforces ACL server-side via the session token supplied on the
    # subscribe frame — exactly like the REST surface, and unlike the
    # master-key-only REST `aggregate` endpoint. The bridge therefore mirrors
    # the SDK's documented scope asymmetry (see CLAUDE.md "Critical Parse Server
    # Behavior"):
    #
    # * **session-token agent** → subscribe with that token; Parse Server
    #   filters events to rows the user can read.
    # * **master-key agent** (no session token, nil ACL scope) → subscribe with
    #   the master key; sees every event.
    # * **`acl_user:` / `acl_role:` agent** → REFUSED. Those scopes are a
    #   mongo-direct-only construct with no REST and no LiveQuery affordance —
    #   Parse Server's LiveQuery has no "act as this user pointer / role"
    #   handshake. Bridging them would silently downgrade to either master-key
    #   (a row-level leak) or an unscoped session, so the bridge fails closed
    #   and raises {Parse::Agent::SecurityError} rather than open a
    #   mis-scoped channel.
    #
    # Only `count` and `samples` URIs are subscribable. `schema` changes are not
    # LiveQuery events, so a `parse://<Class>/schema` subscribe is rejected with
    # {Parse::Agent::ValidationError} rather than silently never firing.
    module MCPSubscriptions
      # Resource kinds that map to a LiveQuery-backed subscription. `schema`
      # is intentionally excluded — class-schema changes do not surface as
      # LiveQuery row events, so a schema subscription could never fire and
      # advertising it would be a broken contract.
      SUBSCRIBABLE_KINDS = %w[count samples].freeze

      # URI grammar shared with {Parse::Agent::MCPDispatcher#handle_resources_read}.
      # Captures (1) the Parse class name and (2) the resource kind.
      URI_RE = %r{\Aparse://([A-Za-z_][A-Za-z0-9_]*)/(schema|count|samples)\z}.freeze

      # Default trailing-debounce window, in seconds. A burst of LiveQuery
      # events on the same `(session, uri)` within this window collapses to a
      # single `notifications/resources/updated`. Bounds notification fan-out
      # on a high-churn class to at most one update per window per subscription.
      DEFAULT_DEBOUNCE_INTERVAL = 0.25

      # Default ceiling on concurrent subscriptions per session. A client that
      # subscribes but never opens (or drops) its GET listening stream leaves
      # LiveQuery subscriptions running until the session is torn down; this cap
      # bounds that footprint, matching the "cap everything" posture of the rest
      # of the transport (`max_concurrent_dispatchers`, the pre-auth limiter).
      DEFAULT_MAX_SUBSCRIPTIONS_PER_SESSION = 100

      # Parse a resource URI into `[class_name, kind]`, enforcing that the kind
      # is LiveQuery-backed.
      #
      # @param uri [String]
      # @return [Array(String, String)] class name and kind.
      # @raise [Parse::Agent::ValidationError] for a malformed URI or a
      #   well-formed-but-unsubscribable kind (e.g. `schema`).
      def self.parse_subscribable_uri(uri)
        match = URI_RE.match(uri.to_s)
        unless match
          raise Parse::Agent::ValidationError,
                "Invalid resource URI: #{uri}. Expected parse://<Class>/{count|samples}."
        end
        class_name = match[1]
        kind       = match[2]
        unless SUBSCRIBABLE_KINDS.include?(kind)
          raise Parse::Agent::ValidationError,
                "Resource kind '#{kind}' is not subscribable — only #{SUBSCRIBABLE_KINDS.join(' and ')} " \
                "are backed by LiveQuery. Schema changes are not LiveQuery events."
        end
        [class_name, kind]
      end

      # Derive LiveQuery subscribe credentials from a subscribing agent.
      #
      # @param agent [Parse::Agent]
      # @return [Hash] keyword fragment for `client.subscribe` — either
      #   `{ session_token: "..." }` or `{ use_master_key: true }`.
      # @raise [Parse::Agent::SecurityError] when the agent's scope has no
      #   LiveQuery equivalent (`acl_user:` / `acl_role:` postures), to avoid
      #   opening a mis-scoped channel.
      def self.live_query_credentials_for(agent)
        token = agent.respond_to?(:session_token) ? agent.session_token : nil
        return { session_token: token } if token && !token.to_s.empty?

        acl_user = agent.respond_to?(:acl_user_scope) ? agent.acl_user_scope : nil
        acl_role = agent.respond_to?(:acl_role_scope) ? agent.acl_role_scope : nil
        if acl_user || acl_role
          raise Parse::Agent::SecurityError,
                "acl_user/acl_role agents cannot open a LiveQuery-backed resource subscription: " \
                "Parse Server LiveQuery has no act-as-user/act-as-role handshake, so the channel " \
                "would be mis-scoped. Subscribe with a session-token or master-key agent instead."
        end

        # Master-key posture: no session token and no acl_user/acl_role (both
        # handled above), so `acl_scope` is nil. But "no scope" is NOT by
        # itself authority to open an ADMIN, ACL-bypassing LiveQuery socket.
        # `client_for` builds that socket via
        # `Parse::LiveQuery::Client.new(use_master_key: true)` with no explicit
        # key, and the constructor backfills the PROCESS-GLOBAL master key
        # (`cfg.master_key || parse_client_value(:master_key)`) — a different
        # authority source than this agent. An unprivileged / client-mode agent
        # whose own client has no master key would otherwise borrow the global
        # one and silently elevate every row on the socket past ACL/CLP. Bind
        # the master-key branch to the agent's ACTUAL authority: its own client
        # must carry a usable (non-blank String) master key — at least as strict
        # as `Parse::LiveQuery::Client#admin_connection?` (which requires a
        # non-empty String). Fail closed otherwise.
        acl_scope = agent.respond_to?(:acl_scope) ? agent.acl_scope : nil
        if acl_scope.nil?
          mk = agent.respond_to?(:client) ? agent.client&.master_key : nil
          return { use_master_key: true } if mk.is_a?(String) && !mk.strip.empty?

          raise Parse::Agent::SecurityError,
                "master-key posture but no master key on the agent's own client; refusing to " \
                "open an admin (ACL-bypassing) LiveQuery socket for an unprivileged agent — it " \
                "would otherwise borrow the process-global master key. Subscribe with a " \
                "session-token agent, or give this agent a master-key client."
        end

        # A scoped posture we don't have a LiveQuery mapping for — fail closed.
        raise Parse::Agent::SecurityError,
              "This agent's scope cannot be safely bridged to LiveQuery; refusing to open a " \
              "resource subscription."
      end

      # In-process {Notifier}. Routes a published notification straight to the
      # listening-stream callback registered under the same session id. This is
      # the single-process implementation; the contract it satisfies is the
      # seam a clustered (e.g. Redis pub/sub) implementation slots into.
      #
      # Contract (any Notifier must honor):
      #   * `register(session_id) { |notification_hash| ... }` — install the
      #     delivery callback for a listening stream. Replacing an existing
      #     registration is allowed (last writer wins).
      #   * `unregister(session_id)` — remove it. Idempotent.
      #   * `publish(session_id, notification_hash)` — deliver to the registered
      #     callback if one exists; a no-op (dropped) when no listener is
      #     attached. Returns whether a listener received it.
      #
      # Thread-safety: `publish` may run on a LiveQuery dispatcher thread while
      # `register`/`unregister` run on Rack I/O threads, so all three guard the
      # listener table with a mutex. The delivery callback itself is invoked
      # outside the lock so a slow consumer can't block registry mutation.
      class LocalNotifier
        def initialize
          @listeners = {}
          @mutex     = Mutex.new
        end

        # @yieldparam notification_hash [Hash] the JSON-RPC notification.
        def register(session_id, &callback)
          return if session_id.nil? || callback.nil?
          @mutex.synchronize { @listeners[session_id] = callback }
        end

        def unregister(session_id)
          return if session_id.nil?
          @mutex.synchronize { @listeners.delete(session_id) }
        end

        # @return [Boolean] true if a listener received the notification.
        def publish(session_id, notification_hash)
          callback = @mutex.synchronize { @listeners[session_id] }
          return false unless callback
          callback.call(notification_hash)
          true
        end

        # @return [Boolean] whether a listening stream is attached.
        def listener?(session_id)
          @mutex.synchronize { @listeners.key?(session_id) }
        end
      end

      # Trailing-debounce coalescer for one `(session, uri)` subscription.
      #
      # The first event in a quiet period arms a one-shot timer; events that
      # arrive before it fires are coalesced (dropped) so the timer emits a
      # single update. After the emit the coalescer rearms on the next event.
      # This bounds emission to at most one notification per window regardless
      # of event rate.
      #
      # The timer mechanism is injected (`timer:`) so tests can drive emission
      # deterministically instead of sleeping. The default spawns a short-lived
      # thread per burst (not per event); at most one timer thread is live per
      # coalescer at a time.
      #
      # @api private
      class Debouncer
        # @param interval [Numeric] debounce window in seconds. `<= 0` emits
        #   synchronously on every trigger (no coalescing) — used by tests and
        #   callers that want immediate delivery.
        # @param timer [#call] `timer.call(interval) { emit }` schedules a
        #   one-shot emit. Default spawns a thread.
        # @yield the emit action invoked once per coalesced burst.
        def initialize(interval:, timer: nil, &emit)
          @interval  = interval
          @emit      = emit
          @timer     = timer || method(:default_timer)
          @armed     = false
          @mutex     = Mutex.new
        end

        # Record an event; arm the timer if not already armed.
        def trigger
          if @interval <= 0
            @emit.call
            return
          end
          should_arm = @mutex.synchronize do
            next false if @armed
            @armed = true
          end
          return unless should_arm
          @timer.call(@interval) do
            @mutex.synchronize { @armed = false }
            @emit.call
          end
        end

        private

        def default_timer(interval, &fire)
          Thread.new do
            sleep interval
            fire.call
          end
        end
      end

      # Per-transport subscription coordinator.
      #
      # One {Manager} is owned by each {Parse::Agent::MCPRackApp} that enables
      # resource subscriptions. It is shared across that app's requests and SSE
      # streams, so every public method is thread-safe.
      #
      # Lifecycle:
      #   1. A GET listening stream opens → {#attach_listener} registers the
      #      stream's delivery callback under its session id.
      #   2. A `resources/subscribe` POST → {#subscribe} validates the URI,
      #      derives credentials from the agent, and starts a LiveQuery
      #      subscription whose events publish debounced updates.
      #   3. `resources/unsubscribe` → {#unsubscribe} stops that one LiveQuery
      #      subscription.
      #   4. The listening stream closes (client disconnect / DELETE session) →
      #      {#detach_listener} tears down every LiveQuery subscription for the
      #      session.
      class Manager
        # @param logger [#warn, nil]
        # @param debounce_interval [Numeric] see {Debouncer}.
        # @param notifier [#register, #unregister, #publish] delivery seam.
        #   Defaults to {LocalNotifier}.
        # @param live_query_client [Object, nil] a single client used for BOTH
        #   master- and session-scoped subscriptions, overriding the
        #   admin/scoped split below. Mainly a test injection point. When set,
        #   `live_query_admin_client` / `live_query_scoped_client` are ignored.
        # @param live_query_admin_client [Object, nil] the client used for
        #   master-key-posture subscriptions. Must be an ADMIN connection
        #   (`Parse::LiveQuery::Client.new(use_master_key: true)`) so the socket
        #   bypasses ACL and the subscription actually sees every matching
        #   object — Parse Server has no per-subscription master key, so a
        #   non-admin connection would silently deliver only publicly-readable
        #   rows. Defaults to a lazily-constructed admin client.
        # @param live_query_scoped_client [Object, nil] the client used for
        #   session-token subscriptions. A normal (non-admin) connection; the
        #   per-subscription `session_token` scopes results to that user.
        #   Defaults to the process-wide `Parse::LiveQuery.client`.
        # @param supported [Boolean, nil] override the {#supported?} result.
        #   When nil (default), {#supported?} reflects the live LiveQuery
        #   enable/availability toggles. Tests pass `true` alongside a fake
        #   client.
        # @param timer [#call, nil] debounce timer mechanism (see {Debouncer}).
        # @param max_subscriptions_per_session [Integer] ceiling on concurrent
        #   subscriptions for one session. {#subscribe} raises
        #   {Parse::Agent::ValidationError} past this. See
        #   {DEFAULT_MAX_SUBSCRIPTIONS_PER_SESSION}.
        def initialize(logger: nil, debounce_interval: DEFAULT_DEBOUNCE_INTERVAL,
                       notifier: nil, live_query_client: nil, supported: nil,
                       timer: nil,
                       live_query_admin_client: nil, live_query_scoped_client: nil,
                       max_subscriptions_per_session: DEFAULT_MAX_SUBSCRIPTIONS_PER_SESSION)
          @logger             = logger
          @debounce_interval  = debounce_interval
          @notifier           = notifier || LocalNotifier.new
          @both_client        = live_query_client
          @admin_client       = live_query_admin_client
          @scoped_client      = live_query_scoped_client
          @supported_override = supported
          @timer              = timer
          @max_per_session    = max_subscriptions_per_session
          @client_mutex       = Mutex.new
          # session_id => { uri => { sub:, debouncer: } }
          @sessions           = Hash.new { |h, k| h[k] = {} }
          @mutex              = Mutex.new
        end

        attr_reader :notifier

        # Whether this transport can honor resource subscriptions. Drives the
        # `resources.subscribe` capability the dispatcher advertises — we never
        # advertise the capability unless we can actually deliver.
        #
        # @return [Boolean]
        def supported?
          return @supported_override unless @supported_override.nil?
          return false unless defined?(Parse::LiveQuery)
          Parse.respond_to?(:live_query_enabled?) && Parse.live_query_enabled? &&
            Parse::LiveQuery.available?
        end

        # Register a listening stream's delivery callback for a session.
        #
        # @param session_id [String]
        # @yieldparam notification_hash [Hash] JSON-RPC notification to deliver.
        # @return [void]
        def attach_listener(session_id, &callback)
          @notifier.register(session_id, &callback)
        end

        # Whether a listening stream is currently attached for the session.
        # @return [Boolean]
        def listener?(session_id)
          @notifier.respond_to?(:listener?) ? @notifier.listener?(session_id) : false
        end

        # Push an arbitrary JSON-RPC message (notification OR a
        # server-initiated request carrying an `id`, e.g.
        # `elicitation/create`) onto the session's listening stream.
        # Returns false when no stream is attached.
        #
        # @param session_id [String]
        # @param message_hash [Hash]
        # @return [Boolean]
        def publish(session_id, message_hash)
          return false unless @notifier.respond_to?(:publish)
          @notifier.publish(session_id, message_hash)
        end

        # Tear down a session: unregister its listener and stop every LiveQuery
        # subscription it opened. Called when the listening stream closes or the
        # session is terminated (DELETE).
        #
        # @param session_id [String]
        # @return [Integer] number of LiveQuery subscriptions stopped.
        def detach_listener(session_id)
          @notifier.unregister(session_id)
          subs = @mutex.synchronize { @sessions.delete(session_id) } || {}
          subs.each_value { |entry| safe_unsubscribe(entry[:sub]) }
          subs.size
        end

        # Open a LiveQuery-backed subscription for a resource URI.
        #
        # @param session_id [String] the Mcp-Session-Id keying the listener.
        # @param uri [String] `parse://<Class>/{count|samples}`.
        # @param agent [Parse::Agent] the subscribing agent (credential source).
        # @return [Boolean] true on success (or already-subscribed no-op).
        # @raise [Parse::Agent::ValidationError] bad/unsubscribable URI, or no
        #   session id.
        # @raise [Parse::Agent::SecurityError] agent scope has no LiveQuery
        #   equivalent.
        def subscribe(session_id:, uri:, agent:)
          if session_id.nil? || session_id.to_s.empty?
            raise Parse::Agent::ValidationError,
                  "resources/subscribe requires an established session (Mcp-Session-Id). " \
                  "Complete initialize first, then open the GET listening stream."
          end
          class_name, resource = MCPSubscriptions.parse_subscribable_uri(uri)

          # Authorization parity with the read path (resources/read →
          # agent.execute → assert_class_accessible!). Enforce agent_hidden, the
          # per-agent `classes:` allowlist, AND CLP BEFORE deriving credentials
          # or opening any socket. Parse Server LiveQuery enforces row ACL/CLP
          # for session-token subscriptions, but agent_hidden / classes: are
          # SDK-only constructs it knows nothing about — and a master-key socket
          # bypasses ACL/CLP entirely. Without this gate,
          # `resources/subscribe parse://_Session/count` (or any operator-hidden
          # PII class) becomes a change/timing oracle on a class the tool
          # surface refuses to even list. The CLP op mirrors the read path
          # exactly — `count` resources gate on `:count`, `samples` on `:find` —
          # so a subscribe is never stricter than the equivalent read. Raises
          # AccessDenied / ValidationError, which the dispatcher maps to
          # JSON-RPC -32602. Called unconditionally (not behind a
          # `defined?(Tools)` guard) so the gate fails CLOSED — if `Tools` were
          # somehow unloaded the call raises rather than silently skipping
          # authorization. `Parse::Agent::Tools` is a hard dependency of the
          # agent stack that mounts this bridge.
          op = resource == "count" ? :count : :find
          Parse::Agent::Tools.assert_class_accessible!(class_name, agent: agent, op: op)

          creds = MCPSubscriptions.live_query_credentials_for(agent)

          # Idempotent: a repeat subscribe to the same URI is a no-op rather
          # than a second LiveQuery socket subscription. Enforce the per-session
          # cap in the same critical section so a burst of distinct-URI
          # subscribes can't race past it.
          @mutex.synchronize do
            subs = @sessions[session_id]
            return true if subs.key?(uri)
            if @max_per_session && subs.size >= @max_per_session
              raise Parse::Agent::ValidationError,
                    "Session subscription limit reached (#{@max_per_session}). " \
                    "Unsubscribe from a resource before adding another."
            end
          end

          debouncer = Debouncer.new(interval: @debounce_interval, timer: @timer) do
            publish_update(session_id, uri)
          end

          sub = client_for(creds).subscribe(class_name, **creds)
          Parse::LiveQuery::EVENTS.each do |event|
            sub.on(event) { debouncer.trigger }
          end

          # Authoritative commit under the lock. The pre-check above is only a
          # fast path — the network subscribe just ran with the lock RELEASED,
          # so in the meantime the session may have been torn down
          # (detach_listener), a racing subscribe may have claimed this URI, or
          # a concurrent burst may have pushed the session to its cap. Re-check
          # before storing, and gate on `@sessions.key?(session_id)` BEFORE
          # indexing: `@sessions` auto-vivifies (`Hash.new { {} }`), so a bare
          # `@sessions[session_id][uri] = …` would silently RESURRECT a detached
          # session and leak its LiveQuery socket for the process lifetime.
          #
          # A subscribe may legitimately arrive before the GET listening stream
          # opens (the session entry exists, just no listener yet); updates
          # published before a listener attaches are dropped by the notifier
          # and start delivering once the stream is up.
          outcome = @mutex.synchronize do
            if !@sessions.key?(session_id)
              :session_gone
            elsif @sessions[session_id].key?(uri)
              :duplicate
            elsif @max_per_session && @sessions[session_id].size >= @max_per_session
              :over_cap
            else
              @sessions[session_id][uri] = { sub: sub, debouncer: debouncer }
              :stored
            end
          end

          case outcome
          when :stored
            true
          when :duplicate
            # A concurrent subscribe to the same URI won; keep theirs and drop
            # the socket we just opened so we don't leak a duplicate.
            safe_unsubscribe(sub)
            true
          when :session_gone
            # The listening stream closed while we were subscribing — don't
            # resurrect it; tear the just-opened socket back down.
            safe_unsubscribe(sub)
            false
          when :over_cap
            safe_unsubscribe(sub)
            raise Parse::Agent::ValidationError,
                  "Session subscription limit reached (#{@max_per_session}). " \
                  "Unsubscribe from a resource before adding another."
          end
        end

        # Stop the LiveQuery subscription for one resource URI. Idempotent.
        #
        # @return [Boolean] true if a subscription was removed.
        def unsubscribe(session_id:, uri:)
          entry = @mutex.synchronize do
            subs = @sessions[session_id]
            e = subs.delete(uri)
            @sessions.delete(session_id) if subs.empty?
            e
          end
          return false unless entry
          safe_unsubscribe(entry[:sub])
          true
        end

        # @return [Integer] number of active (session, uri) subscriptions.
        def subscription_count
          @mutex.synchronize { @sessions.values.sum(&:size) }
        end

        private

        # Pick the LiveQuery connection appropriate to the derived credentials.
        #
        # Parse Server has no per-subscription master key: ACL-bypass is fixed
        # at connect time. So a master-key-posture subscription MUST ride an
        # admin connection (one socket authenticated with the master key) to
        # see ACL-restricted rows; a session-token subscription rides a normal
        # connection and is scoped by the per-subscription token. We therefore
        # keep two clients and route by credential. An injected single client
        # (tests) overrides the split.
        def client_for(creds)
          return @both_client if @both_client
          if creds[:use_master_key]
            @client_mutex.synchronize do
              @admin_client ||= Parse::LiveQuery::Client.new(use_master_key: true)
            end
          else
            # A session-token subscription MUST ride an ACL-scoped connection.
            # `Parse::LiveQuery.client` inherits `config.use_master_key`, so a
            # global `Parse::LiveQuery.configure { |c| c.use_master_key = true }`
            # would make this shared client an ADMIN (ACL-bypassing) socket —
            # and because Parse Server fixes ACL-bypass per-connection at connect
            # time (no per-subscription master key), every session-token
            # subscription on it would then deliver change events for rows the
            # user cannot read. Fail closed rather than open a mis-scoped
            # channel, mirroring the master-key branch's authority gate.
            sc = @client_mutex.synchronize { @scoped_client ||= Parse::LiveQuery.client }
            if sc.respond_to?(:admin_connection?) && sc.admin_connection?
              raise Parse::Agent::SecurityError,
                    "the scoped LiveQuery client is an admin (master-key) connection " \
                    "(config.use_master_key = true); refusing to bridge a session-token " \
                    "subscription over an ACL-bypassing socket. Configure a non-admin " \
                    "LiveQuery client for scoped subscriptions."
            end
            sc
          end
        end

        # Emit one coarse resources/updated for the URI through the notifier.
        def publish_update(session_id, uri)
          notification = {
            "jsonrpc" => "2.0",
            "method"  => "notifications/resources/updated",
            "params"  => { "uri" => uri },
          }
          @notifier.publish(session_id, notification)
        rescue StandardError => e
          warn_logger("publish error for #{uri}: #{e.class}: #{e.message}")
        end

        def safe_unsubscribe(sub)
          sub&.unsubscribe
        rescue StandardError => e
          warn_logger("LiveQuery unsubscribe error: #{e.class}: #{e.message}")
        end

        def warn_logger(line)
          full = "[Parse::Agent::MCPSubscriptions::Manager] #{line}"
          @logger ? @logger.warn(full) : warn(full)
        end
      end
    end
  end
end
