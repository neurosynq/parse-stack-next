# encoding: UTF-8
# frozen_string_literal: true

module Parse
  class Agent
    # Supported MCP deployment patterns, packaged as {MCPRackApp} factories.
    #
    # Two explicit access modes, so a deployment can never drift from one into
    # the other by accident:
    #
    # * {MCPRackApp.user_scoped}: every request carries a Parse session token.
    #   The agent acts as that user (ACL/CLP enforced by Parse Server on REST
    #   and by the SDK on mongo-direct paths). A missing, blank, invalid,
    #   expired, or revoked token is refused with 401 before any agent is
    #   built, and there is no fallback to master-key access.
    #
    # * {MCPRackApp.master_analytics}: master authority for analytics and
    #   trusted operational tools, narrowed by the agent's configured tools,
    #   classes, and fields, and read-only by default. Operator identity is
    #   mandatory: without a `principal_resolver` every master-key agent
    #   fingerprints as the same principal, and callers would share ownership
    #   of each other's streams, approvals, and cancellations.
    #
    # Direct `MCPRackApp.new(agent_factory: ...)` construction is unchanged
    # and remains the way to build anything else, including an intentional
    # single-operator master-key endpoint.
    class MCPRackApp
      # Default seconds between identity re-checks on a user-scoped listening
      # stream. Bounds how long a revoked session keeps receiving
      # notifications on an already-open stream.
      DEFAULT_SESSION_REVALIDATE_INTERVAL = 60

      # Rack env key where `user_scoped` records the verified user id for the
      # request, read back by its principal resolver.
      USER_PRINCIPAL_ENV_KEY = "parse.agent.user_scoped.user_id"

      # Raised by {validate_session!} when Parse Server could not be asked
      # (unreachable, 5xx, an unexpected error). Distinct from
      # {Parse::Agent::Unauthorized}, which means the session was rejected.
      class SessionCheckUnavailable < StandardError; end

      # Accepted values for `session_validation:`.
      SESSION_VALIDATION_MODES = %i[per_request cached].freeze

      # One rate limiter per principal, shared by every agent a deployment
      # factory builds for that principal. A factory builds a fresh agent per
      # request, and each agent would otherwise get a fresh limiter, so the
      # configured rate limit never accumulated across requests. Bounded
      # (least recently used) so a stream of principals cannot grow it
      # without limit; an evicted principal starts a new window.
      class PrincipalRateLimiters
        DEFAULT_MAX_ENTRIES = 10_000

        def initialize(limit:, window:, max_entries: DEFAULT_MAX_ENTRIES)
          @limit = limit
          @window = window
          @max = max_entries
          @limiters = {}
          @mutex = Mutex.new
        end

        # @param principal [String]
        # @return [Parse::Agent::RateLimiter]
        def fetch(principal)
          key = principal.to_s
          @mutex.synchronize do
            limiter = @limiters.delete(key) || Parse::Agent::RateLimiter.new(limit: @limit, window: @window)
            @limiters[key] = limiter
            @limiters.shift while @limiters.size > @max
            limiter
          end
        end

        def size
          @mutex.synchronize { @limiters.size }
        end
      end

      # @api private
      # The registry a factory uses, or nil when the caller injected its own
      # `rate_limiter:` (honored as-is, e.g. a shared Redis limiter).
      def self.principal_rate_limiters_for(agent_options)
        # Only a real injected limiter bypasses the registry; an explicit
        # `rate_limiter: nil` would otherwise give every request a fresh one.
        return nil unless agent_options[:rate_limiter].nil?
        PrincipalRateLimiters.new(
          limit: agent_options.fetch(:rate_limit, Parse::Agent::DEFAULT_RATE_LIMIT),
          window: agent_options.fetch(:rate_window, Parse::Agent::DEFAULT_RATE_WINDOW),
        )
      end

      # Options that would give a user-scoped agent authority beyond its
      # session, refused by {MCPRackApp.user_scoped}.
      USER_SCOPED_REFUSED_AGENT_OPTIONS = %i[master_atlas allow_mutations].freeze

      # Agent constructor options a factory owns. Passing them through
      # `agent_options:` would let configuration override the identity or
      # authority the factory pins, so they are refused at construction.
      FACTORY_OWNED_AGENT_OPTIONS = %i[
        session_token acl_user acl_role
        impersonate_user impersonation_user impersonate_mint impersonation_mint
        impersonate_label impersonation_label
        tenant_id client permissions permission parent
      ].freeze

      # Rack app options a factory owns.
      FACTORY_OWNED_APP_OPTIONS = %i[
        agent_factory principal_resolver
        listening_stream_revalidator listening_stream_revalidate_interval
      ].freeze

      # Default session-token extraction: `Authorization: Bearer <token>`,
      # else `X-Parse-Session-Token`.
      DEFAULT_SESSION_TOKEN_FROM = lambda do |env|
        auth = env["HTTP_AUTHORIZATION"].to_s.strip
        if (m = auth.match(/\ABearer\s+(\S+)\z/i))
          m[1]
        else
          env["HTTP_X_PARSE_SESSION_TOKEN"]
        end
      end

      class << self
        # Build an MCP endpoint whose agents act as the calling Parse user.
        #
        # Every request (POST and the GET listening stream) must carry a
        # session token. The token is validated before an agent is built;
        # anything missing, blank, invalid, expired, or revoked gets 401.
        # The resulting agent is `Parse::Agent.new(session_token: token, ...)`,
        # so identity comes from the session and cannot be changed by tool
        # arguments. There is no master-key fallback in this mode.
        #
        # **Revocation.** With the default `session_validation: :per_request`,
        # each request re-checks the token against Parse Server
        # (`GET /users/me`, uncached), so a logged-out, expired, or revoked
        # session is refused on the next request. An already-open listening
        # stream is re-checked every `session_revalidate_interval` seconds and
        # closed (tearing down its subscriptions) when the check fails.
        # `session_validation: :cached` trades that for fewer round trips: the
        # token is resolved through `client.authorization`, so revocation takes
        # effect after the identity-cache TTL unless the
        # `Parse::Cache::Invalidation` hooks evict it first. See the "Deployment
        # patterns" section of the MCP guide for the full interval table.
        #
        # @param session_token_from [#call, nil] `->(env) { token }`. Defaults
        #   to {DEFAULT_SESSION_TOKEN_FROM}.
        # @param permissions [Symbol] agent permission tier; `:readonly`
        #   (default), `:write`, or `:admin`. Writes still flow only through
        #   declared `agent_method`s and the existing env gates.
        # @param client [Parse::Client, nil] the client to validate tokens and
        #   build agents against. nil uses `Parse.client` at request time.
        # @param tenant_from [#call, nil] `->(env, user_id) { tenant }` to pin
        #   the agent's `tenant_id` server-side. A nil or blank result is
        #   refused with 401 (fail closed).
        # @param session_validation [Symbol] `:per_request` (default) or
        #   `:cached`. See above.
        # @param session_revalidate_interval [Numeric] seconds between identity
        #   re-checks on an open listening stream.
        # @param agent_options [Hash] extra `Parse::Agent.new` options (for
        #   example `tools:`, `methods:`, `classes:`, `filters:`). Identity and
        #   authority options in {FACTORY_OWNED_AGENT_OPTIONS} are refused.
        # @param rack_options [Hash] remaining `MCPRackApp.new` options
        #   (`transport:`, `logger:`, `allowed_origins:`, ...). Options in
        #   {FACTORY_OWNED_APP_OPTIONS} are refused.
        # @return [MCPRackApp]
        # @raise [ArgumentError] on a factory-owned option or invalid setting.
        def user_scoped(session_token_from: nil, permissions: :readonly, client: nil,
                        tenant_from: nil, session_validation: :per_request,
                        session_revalidate_interval: DEFAULT_SESSION_REVALIDATE_INTERVAL,
                        agent_options: {}, **rack_options, &block)
          raise ArgumentError, "MCPRackApp.user_scoped builds its own agent factory; do not pass a block" if block
          if permissions.to_s == "admin"
            # The admin tier skips the spend cap and score quantization, which
            # are cost and inference controls meant for untrusted callers. Every
            # signed-in user of this endpoint would inherit that exemption.
            raise ArgumentError,
                  "MCPRackApp.user_scoped does not accept permissions: :admin; use :readonly or :write"
          end
          assert_factory_options!(:user_scoped, agent_options, rack_options)
          extractor = session_token_from || DEFAULT_SESSION_TOKEN_FROM
          raise ArgumentError, "session_token_from must respond to #call" unless extractor.respond_to?(:call)
          if tenant_from && !tenant_from.respond_to?(:call)
            raise ArgumentError, "tenant_from must respond to #call"
          end
          unless SESSION_VALIDATION_MODES.include?(session_validation)
            raise ArgumentError,
                  "session_validation must be one of #{SESSION_VALIDATION_MODES.inspect} " \
                  "(got #{session_validation.inspect})"
          end
          options = agent_options.dup.freeze
          limiters = Parse::Agent::MCPRackApp.principal_rate_limiters_for(options)

          factory = lambda do |env|
            token = extractor.call(env).to_s.strip
            raise Parse::Agent::Unauthorized.new("Missing session token", reason: :missing_session) if token.empty?

            parse_client = client || Parse.client
            user_id = begin
                validate_session!(parse_client, token, mode: session_validation)
              rescue SessionCheckUnavailable
                # Fail closed for the request, but keep the token cached: the
                # session may well be valid once Parse Server answers again.
                raise Parse::Agent::Unauthorized.new("Session could not be verified",
                                                     reason: :session_check_unavailable)
              end
            # The verified user id is the session's principal, so a refreshed
            # token (or a second login) for the same user keeps its sessions,
            # and per-principal bounds apply per user rather than per token.
            env[USER_PRINCIPAL_ENV_KEY] = user_id
            kwargs = options.merge(session_token: token, permissions: permissions)
            kwargs[:client] = client if client
            kwargs[:rate_limiter] = limiters.fetch("user:#{user_id}") if limiters
            if tenant_from
              tenant = tenant_from.call(env, user_id)
              if tenant.nil? || tenant.to_s.strip.empty?
                raise Parse::Agent::Unauthorized.new("No tenant for session", reason: :missing_tenant)
              end
              kwargs[:tenant_id] = tenant
            end
            Parse::Agent.new(**kwargs)
          end

          # A session Parse Server reports invalid closes the stream at once.
          # SessionCheckUnavailable (Parse Server unreachable, a 5xx) is left
          # to propagate, so the stream's revalidation loop counts it as a
          # transient error and only closes after repeated failures.
          revalidator = lambda do |agent|
            token = agent.respond_to?(:session_token) ? agent.session_token.to_s : ""
            return false if token.empty?
            validate_session!(client || Parse.client, token, mode: :per_request)
            true
          rescue Parse::Agent::Unauthorized
            false
          end

          resolver = ->(_agent, env) { (uid = env[USER_PRINCIPAL_ENV_KEY]) ? "user:#{uid}" : nil }

          new(agent_factory: factory,
              principal_resolver: resolver,
              listening_stream_revalidator: revalidator,
              listening_stream_revalidate_interval: session_revalidate_interval,
              **rack_options)
        end

        # Build an MCP endpoint whose agents use master authority, for
        # analytics and trusted operational tools.
        #
        # `principal_resolver:` is required and must identify the operator
        # behind each request (`->(agent, env) { "op:#{verified_id}" }`). It
        # is used for session ownership (streams, approvals, cancellations)
        # and audit; a request it cannot resolve (nil or blank) is refused
        # with 401. Master authority governs what data the agent may reach;
        # the agent's configured `tools:`, `classes:`, `filters:`, and field
        # policy govern what it may actually do. Read-only by default.
        #
        # @param principal_resolver [#call] `->(agent, env) { principal }`.
        #   Required.
        # @param permissions [Symbol] defaults to `:readonly`.
        # @param client [Parse::Client, nil] a client configured with the
        #   master key. nil uses `Parse.client` at request time.
        # @param tenant_from [#call, nil] `->(env, principal) { tenant }` to pin
        #   `tenant_id`; nil or blank is refused with 401.
        # @param agent_options [Hash] extra `Parse::Agent.new` options.
        #   Identity and authority options are refused.
        # @param rack_options [Hash] remaining `MCPRackApp.new` options.
        # @return [MCPRackApp]
        # @raise [ArgumentError] without a callable `principal_resolver`, or on
        #   a factory-owned option.
        def master_analytics(principal_resolver:, permissions: :readonly, client: nil,
                             tenant_from: nil, agent_options: {}, **rack_options, &block)
          raise ArgumentError, "MCPRackApp.master_analytics builds its own agent factory; do not pass a block" if block
          unless principal_resolver.respond_to?(:call)
            raise ArgumentError,
                  "MCPRackApp.master_analytics requires principal_resolver: (->(agent, env) { operator_id }). " \
                  "Without it every master-key agent shares one principal, so callers could attach to, " \
                  "approve, or cancel each other's sessions. For a deliberate single-operator endpoint, " \
                  "build MCPRackApp.new(agent_factory: ...) directly."
          end
          if tenant_from && !tenant_from.respond_to?(:call)
            raise ArgumentError, "tenant_from must respond to #call"
          end
          assert_factory_options!(:master_analytics, agent_options, rack_options)
          options = agent_options.dup.freeze
          limiters = Parse::Agent::MCPRackApp.principal_rate_limiters_for(options)

          # Resolve once per request and reuse it for ownership, so the
          # resolver's identity check is not repeated (and cannot disagree
          # with itself) between the factory and the fingerprint.
          memo_key = "parse.mcp.analytics_principal"
          resolver = lambda do |agent, env|
            env.key?(memo_key) ? env[memo_key] : (env[memo_key] = principal_resolver.call(agent, env))
          end

          factory = lambda do |env|
            parse_client = client || Parse.client
            unless parse_client.respond_to?(:master_key) && !parse_client.master_key.to_s.empty?
              raise Parse::Agent::Unauthorized.new("master_analytics requires a master-key client",
                                                   reason: :no_master_key)
            end
            kwargs = options.merge(permissions: permissions)
            kwargs[:client] = client if client
            agent = Parse::Agent.new(**kwargs)
            principal = resolver.call(agent, env)
            if principal.nil? || principal.to_s.strip.empty?
              raise Parse::Agent::Unauthorized.new("Unidentified operator", reason: :missing_principal)
            end
            # The operator is known only once an agent exists (the resolver
            # receives it), so rebuild this request's agent with the
            # operator's shared limiter.
            agent = Parse::Agent.new(**kwargs, rate_limiter: limiters.fetch("op:#{principal}")) if limiters
            if tenant_from
              tenant = tenant_from.call(env, principal)
              if tenant.nil? || tenant.to_s.strip.empty?
                raise Parse::Agent::Unauthorized.new("No tenant for operator", reason: :missing_tenant)
              end
              agent.tenant_id = tenant
            end
            agent
          end

          new(agent_factory: factory, principal_resolver: resolver, **rack_options)
        end

        # Validate a session token and return its user id, or raise
        # {Parse::Agent::Unauthorized}.
        #
        # `:per_request` asks Parse Server directly (`GET /users/me`, response
        # cache bypassed) and, on failure, evicts the token from the client's
        # authorization identity cache so mongo-direct paths stop trusting it
        # too. `:cached` resolves through `client.authorization` (identity
        # cache, then `/users/me` on a miss).
        #
        # @api private
        def validate_session!(parse_client, token, mode:)
          if mode == :cached
            begin
              resolved = parse_client.authorization.resolve(token)
            rescue Parse::Authorization::InvalidSession
              raise Parse::Agent::Unauthorized.new("Invalid session", reason: :invalid_session)
            end
            user_id = resolved.respond_to?(:user_id) ? resolved.user_id : nil
            raise Parse::Agent::Unauthorized.new("Invalid session", reason: :invalid_session) if user_id.to_s.empty?
            return user_id.to_s
          end

          response = begin
              parse_client.current_user(token, cache: false)
            rescue StandardError => e
              raise SessionCheckUnavailable, "session check failed: #{e.class}"
            end
          if response.nil?
            raise SessionCheckUnavailable, "session check returned no response"
          end
          if response.error? && !session_rejected?(response)
            # Parse Server could not answer (5xx, timeout, an unexpected
            # error code). That says nothing about the session, so it is
            # neither accepted nor evicted from the identity cache.
            raise SessionCheckUnavailable, "session check failed (#{response.http_status || response.code})"
          end
          result = response.error? ? nil : response.result
          user_id = result.is_a?(Hash) ? (result["objectId"] || result[:objectId]) : nil
          if user_id.to_s.empty?
            if parse_client.respond_to?(:authorization) && parse_client.authorization.respond_to?(:invalidate)
              parse_client.authorization.invalidate(token)
            end
            raise Parse::Agent::Unauthorized.new("Invalid session", reason: :invalid_session)
          end
          user_id.to_s
        end

        private

        # True when Parse Server rejected the session itself (invalid or
        # expired token, or an auth failure), as opposed to failing to answer.
        def session_rejected?(response)
          return true if response.respond_to?(:permission_denied?) && response.permission_denied?
          code = response.respond_to?(:code) ? response.code : nil
          code == Parse::Response::ERROR_INVALID_SESSION_TOKEN || code == 101
        end

        def assert_factory_options!(factory_name, agent_options, rack_options)
          unless agent_options.is_a?(Hash)
            raise ArgumentError, "#{factory_name}: agent_options must be a Hash"
          end
          owned = agent_options.keys.map(&:to_sym) & FACTORY_OWNED_AGENT_OPTIONS
          unless owned.empty?
            raise ArgumentError,
                  "#{factory_name}: agent_options may not set #{owned.inspect}; the factory owns " \
                  "identity and authority (use the factory's own keyword where one exists)"
          end
          if factory_name == :user_scoped
            # A signed-in user's agent must not be handed authority beyond
            # its session: master Atlas reach (unscoped $searchMeta counts)
            # or the mutation override.
            elevated = agent_options.keys.map(&:to_sym) & USER_SCOPED_REFUSED_AGENT_OPTIONS
            unless elevated.empty?
              raise ArgumentError,
                    "user_scoped: agent_options may not set #{elevated.inspect}; a user-scoped " \
                    "agent never receives authority beyond its session"
            end
          end
          owned_app = rack_options.keys.map(&:to_sym) & FACTORY_OWNED_APP_OPTIONS
          unless owned_app.empty?
            raise ArgumentError, "#{factory_name}: #{owned_app.inspect} are set by the factory"
          end
        end
      end
    end
  end
end
