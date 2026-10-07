# encoding: UTF-8
# frozen_string_literal: true

require "open-uri"

module Parse
  module API
    # Defines the User class interface for the Parse REST API
    module Users
      # @!visibility private
      USER_PATH_PREFIX = "users"
      # @!visibility private
      LOGOUT_PATH = "logout"
      # @!visibility private
      LOGIN_PATH = "login"
      # @!visibility private
      VERIFY_PASSWORD_PATH = "verifyPassword"
      # @!visibility private
      REQUEST_PASSWORD_RESET = "requestPasswordReset"
      # @!visibility private
      VERIFICATION_EMAIL_REQUEST = "verificationEmailRequest"

      # Fetch a {Parse::User} for a given objectId.
      # @param id [String] the user objectid
      # @param opts [Hash] additional options to pass to the {Parse::Client} request.
      # @param headers [Hash] additional HTTP headers to send with the request.
      # @return [Parse::Response]
      def fetch_user(id, headers: {}, **opts)
        id = Parse::API::PathSegment.object_id!(id)
        request :get, "#{USER_PATH_PREFIX}/#{id}", headers: headers, opts: opts
      end

      # Find users matching a set of constraints.
      # @param query [Hash] query parameters.
      # @param opts [Hash] additional options to pass to the {Parse::Client} request.
      # @param headers [Hash] additional HTTP headers to send with the request.
      # @return [Parse::Response]
      def find_users(query = {}, headers: {}, **opts)
        response = request :get, USER_PATH_PREFIX, query: query, headers: headers, opts: opts
        response.parse_class = Parse::Model::CLASS_USER
        response
      end

      # Find user matching this active session token.
      # @param session_token [String] the Parse user session token to look up.
      # @param opts [Hash] additional options to pass to the {Parse::Client} request.
      # @param headers [Hash] additional HTTP headers to send with the request.
      # @return [Parse::Response]
      def current_user(session_token, headers: {}, **opts)
        # The token argument is the whole point of this call, so it is passed
        # as the explicit per-call token: an ambient `Parse.with_session`
        # token or a client-bound token must never replace it (that resolved
        # the wrong user and poisoned the identity cache). A caller-supplied
        # `session_token:` in opts is ignored for the same reason.
        session_token = session_token.session_token if session_token.respond_to?(:session_token)
        opts = opts.merge(session_token: session_token.to_s, use_master_key: false)
        headers = headers.merge({ Parse::Protocol::SESSION_TOKEN => session_token.to_s })
        response = request :get, "#{USER_PATH_PREFIX}/me", headers: headers, opts: opts
        response.parse_class = Parse::Model::CLASS_USER
        response
      end

      # Create a new user.
      # @param body [Hash] a hash of values related to your _User schema.
      # @param opts [Hash] additional options to pass to the {Parse::Client} request.
      # @param headers [Hash] additional HTTP headers to send with the request.
      # @return [Parse::Response]
      #
      # Sent WITHOUT the master key unless the caller passes
      # `use_master_key: true`. Parse Server does not mint a session token for
      # a master-key signup, so a master-keyed client used to get back a user
      # with no `sessionToken` (and {Parse::User#upgrade_anonymous!} then
      # failed). A master-key create also lets the request through `_User`
      # create CLPs and authData checks that a real signup must pass.
      def create_user(body, headers: {}, **opts)
        opts = opts.merge(use_master_key: false) unless opts[:use_master_key] == true
        headers = headers.merge({ Parse::Protocol::REVOCABLE_SESSION => "1" })
        if opts[:session_token].present?
          headers = headers.merge({ Parse::Protocol::SESSION_TOKEN => opts[:session_token] })
        elsif opts[:use_master_key] != true
          # No token given: send none, rather than letting an ambient
          # `with_session` token or a client-bound token make the caller the
          # `request.user` of someone else's signup.
          opts = opts.merge(session_token: "")
        end
        response = request :post, USER_PATH_PREFIX, body: body, headers: headers, opts: opts
        response.parse_class = Parse::Model::CLASS_USER
        response
      end

      # Update a {Parse::User} record given an objectId.
      # @param id [String] the Parse user objectId.
      # @param body [Hash] the body of the API request.
      # @param opts [Hash] additional options to pass to the {Parse::Client} request.
      # @param headers [Hash] additional HTTP headers to send with the request.
      # @return [Parse::Response]
      def update_user(id, body = {}, headers: {}, **opts)
        id = Parse::API::PathSegment.object_id!(id)
        response = request :put, "#{USER_PATH_PREFIX}/#{id}", body: body, headers: headers, opts: opts
        response.parse_class = Parse::Model::CLASS_USER
        # A password change revokes the user's other sessions server-side.
        if response.success? && body.is_a?(Hash) && (body.key?(:password) || body.key?("password"))
          invalidate_user_identity(id)
        end
        response
      end

      # Set the authentication service OAUth data for a user. Deleting or unlinking
      # is done by setting the authData of the service name to nil.
      # @param id [String] the Parse user objectId.
      # @param service_name [Symbol] the name of the OAuth service.
      # @param auth_data [Hash] the hash data related to the third-party service.
      # @param opts [Hash] additional options to pass to the {Parse::Client} request.
      # @param headers [Hash] additional HTTP headers to send with the request.
      # @return [Parse::Response]
      def set_service_auth_data(id, service_name, auth_data, headers: {}, **opts)
        body = { authData: { service_name => auth_data } }
        update_user(id, body, headers: headers, **opts)
      end

      # Delete a {Parse::User} record given an objectId.
      # @param id [String] the Parse user objectId.
      # @param opts [Hash] additional options to pass to the {Parse::Client} request.
      # @param headers [Hash] additional HTTP headers to send with the request.
      # @return [Parse::Response]
      def delete_user(id, headers: {}, **opts)
        id = Parse::API::PathSegment.object_id!(id)
        response = request :delete, "#{USER_PATH_PREFIX}/#{id}", headers: headers, opts: opts
        invalidate_user_identity(id) if response.success?
        response
      end

      # Request a password reset for a registered email.
      #
      # Client-side rate limited on a per-email basis using the same
      # tracker that backs {#login} (entries are namespaced under a
      # `pwreset:` prefix so the two limiters don't collide on usernames
      # that happen to equal an email). Every request counts toward the
      # backoff — Parse Server's `requestPasswordReset` response does
      # not differentiate "email exists" from "email does not exist"
      # (and rightly so, to avoid account enumeration), so the SDK
      # cannot distinguish a legitimate retry from an attacker probing
      # for valid emails. The cap mirrors {LOGIN_MAX_FAILURES}: 5
      # requests within the rolling window before exponential backoff
      # kicks in and the limit clears via the same TTL-based cleanup.
      #
      # @param email [String] the Parse user email.
      # @param opts [Hash] additional options to pass to the {Parse::Client} request.
      # @param headers [Hash] additional HTTP headers to send with the request.
      # @raise [RuntimeError] when the per-email request rate is exceeded.
      # @return [Parse::Response]
      def request_password_reset(email, headers: {}, **opts)
        rate_key = "pwreset:#{email}"
        check_login_rate_limit!(rate_key)
        body = { email: email }
        response = request :post, REQUEST_PASSWORD_RESET, body: body, opts: unauthenticated_opts(opts), headers: headers
        # Always count the attempt as a "failure" for backoff purposes:
        # the response body is intentionally indistinguishable across
        # found/not-found emails, so we cannot reset the counter on
        # "success" without leaking that distinction to an attacker who
        # is probing.
        track_login_attempt(rate_key, false)
        response
      end

      # Request that Parse Server (re)send the email-address verification email
      # for a registered, not-yet-verified user. Requires the server to have an
      # email adapter and `verifyUserEmails` enabled; otherwise Parse Server
      # responds with an error. Rate-limited per email like password reset.
      #
      # @param email [String] the Parse user email.
      # @param opts [Hash] additional options to pass to the {Parse::Client} request.
      # @param headers [Hash] additional HTTP headers to send with the request.
      # @return [Parse::Response]
      def request_email_verification(email, headers: {}, **opts)
        rate_key = "emailverify:#{email}"
        check_login_rate_limit!(rate_key)
        body = { email: email }
        response = request :post, VERIFICATION_EMAIL_REQUEST, body: body, opts: unauthenticated_opts(opts), headers: headers
        # Indistinguishable found/not-found response, like password reset — count
        # every attempt toward backoff so probing can't reset the counter.
        track_login_attempt(rate_key, false)
        response
      end

      # Login a user. Implements client-side rate limiting with exponential
      # backoff after repeated failures to mitigate brute force attacks.
      # @param username [String] the Parse user username.
      # @param password [String] the Parse user's associated password.
      # @param headers [Hash] additional HTTP headers to send with the request.
      # @param opts [Hash] additional options to pass to the {Parse::Client} request.
      # @return [Parse::Response]
      #
      # Always sent without the master key and without any ambient or bound
      # session token (see {#unauthenticated_opts}). A master-key login makes
      # Parse Server skip the additional MFA check and SAVE the submitted
      # authData, so it must never be sent from a master-keyed client.
      def login(username, password, headers: {}, **opts)
        check_login_rate_limit!(username)
        body = { username: username, password: password }
        headers = headers.merge({ Parse::Protocol::REVOCABLE_SESSION => "1" })
        response = request :post, LOGIN_PATH, body: body, headers: headers, opts: unauthenticated_opts(opts)
        response.parse_class = Parse::Model::CLASS_USER
        track_login_attempt(username, response.success?)
        response
      end

      # Login a user with MFA (Multi-Factor Authentication).
      #
      # This method handles Parse Server's MFA adapter which requires both
      # standard credentials AND an MFA token when MFA is enabled for the user.
      #
      # @param username [String] the Parse user username.
      # @param password [String] the Parse user's associated password.
      # @param mfa_token [String] the TOTP code from authenticator app or recovery code.
      # @param headers [Hash] additional HTTP headers to send with the request.
      # @param opts [Hash] additional options to pass to the {Parse::Client} request.
      # @return [Parse::Response]
      #
      # @example
      #   response = client.login_with_mfa("john", "password123", "123456")
      def login_with_mfa(username, password, mfa_token, headers: {}, **opts)
        check_login_rate_limit!(username)
        # Parse Server expects authData to be sent with POST for MFA login
        body = {
          username: username,
          password: password,
          authData: {
            mfa: {
              token: mfa_token,
            },
          },
        }
        # Never with the master key: with it, Parse Server skips the MFA
        # validation and stores the submitted `authData.mfa` over the
        # account's enrolled TOTP secret, so any code "verifies" and MFA is
        # silently broken for the account from then on.
        headers = headers.merge({ Parse::Protocol::REVOCABLE_SESSION => "1" })
        response = request :post, LOGIN_PATH, body: body, headers: headers, opts: unauthenticated_opts(opts)
        response.parse_class = Parse::Model::CLASS_USER
        track_login_attempt(username, response.success?)
        response
      end

      # Verify a user's credentials against Parse Server without minting a session.
      # This is the canonical step-up / re-authentication primitive: it confirms
      # that the username + password combination is correct without producing a
      # new session token on success.
      #
      # Uses the `POST /parse/verifyPassword` endpoint (credentials in the request
      # BODY, mirroring `login`) rather than the `GET` form. Parse Server accepts
      # both (same handler, neither master-key gated; the POST variant landed in
      # 7.1.0), but POST keeps the plaintext password out of the URL — and
      # therefore out of server access logs, reverse-proxy logs, the `Referer`
      # header, and the SDK's URL-keyed response cache.
      #
      # On success Parse Server returns the user object (HTTP 200) with the same
      # shape as a login response (minus `sessionToken`). On failure it returns a
      # 4xx with an error body, most commonly:
      # - code 101 (`ERROR_OBJECT_NOT_FOUND`) for an unknown username or wrong password.
      # - code 205 (`ERROR_EMAIL_NOT_FOUND`) when `preventLoginWithUnverifiedEmail`
      #   is enabled and the account's email has not been verified.
      #
      # Client-side rate limited per username using the SAME bucket as {#login}
      # (bare username, no namespace) — failures across both credential oracles
      # accumulate, so an attacker cannot bypass a `login` lockout by pivoting to
      # this endpoint. The trade-off: a run of failed step-up re-auth calls counts
      # toward (and can trigger) the primary login lockout for that username.
      # Client-side limiting is a convenience, not a boundary — the server is the
      # real control.
      #
      # @param username [String] the Parse user username.
      # @param password [String] the Parse user's associated password.
      # @param headers [Hash] additional HTTP headers to send with the request.
      # @param opts [Hash] additional options to pass to the {Parse::Client} request.
      # @return [Parse::Response]
      def verify_password(username, password, headers: {}, **opts)
        check_login_rate_limit!(username)
        body = { username: username, password: password }
        response = request :post, VERIFY_PASSWORD_PATH, body: body, headers: headers, opts: unauthenticated_opts(opts)
        response.parse_class = Parse::Model::CLASS_USER
        track_login_attempt(username, response.success?)
        response
      end

      # Logout a user by deleting the associated session.
      # @param session_token [String] the Parse user session token to delete.
      # @param headers [Hash] additional HTTP headers to send with the request.
      # @param opts [Hash] additional options to pass to the {Parse::Client} request.
      # @return [Parse::Response]
      def logout(session_token, headers: {}, **opts)
        session_token = session_token.session_token if session_token.respond_to?(:session_token)
        headers = headers.merge({ Parse::Protocol::SESSION_TOKEN => session_token })
        opts = opts.merge({ use_master_key: false, session_token: session_token })
        response = request :post, LOGOUT_PATH, headers: headers, opts: opts
        # Forget the token in this client's identity plane so mongo-direct
        # reads see the revocation now rather than when the entry expires.
        invalidate_session_identity(session_token) if response.success?
        response
      end

      # Signup a user given a username, password and, optionally, their email.
      # @param username [String] the Parse user username.
      # @param password [String] the Parse user's associated password.
      # @param email [String] the desired Parse user's email.
      # @param body [Hash] additional property values to pass when creating the user record.
      # @param opts [Hash] additional options to pass to the {Parse::Client} request.
      # @return [Parse::Response]
      def signup(username, password, email = nil, body: {}, **opts)
        body = body.merge({ username: username, password: password })
        body[:email] = email || body[:email]
        create_user(body, **opts)
      end

      # Drop one session token from this client's identity plane.
      # @!visibility private
      # @param session_token [String]
      def invalidate_session_identity(session_token)
        return if session_token.nil? || session_token.to_s.empty?
        authorization.invalidate(session_token) if respond_to?(:authorization)
      rescue StandardError
        nil
      end

      # Drop every identity entry that resolves to `user_id` from this
      # client's identity plane, after an event that revokes the user's
      # sessions (password change, account deletion, logout everywhere).
      # @!visibility private
      # @param user_id [String]
      def invalidate_user_identity(user_id)
        return if user_id.nil? || user_id.to_s.empty?
        authorization.invalidate_user(user_id) if respond_to?(:authorization)
      rescue StandardError
        nil
      end

      private

      # Request options for an endpoint that authenticates by the request
      # body itself (login, MFA login, verifyPassword, password reset,
      # verification email). Forces the master key off, and passes an
      # explicitly blank session token so neither the ambient
      # `Parse.with_session` token nor a client-bound token is attached:
      # {Parse::Client#request} treats an explicit blank token as "send no
      # credential". A caller cannot opt back into the master key here.
      # @!visibility private
      def unauthenticated_opts(opts)
        opts.merge(use_master_key: false, session_token: "")
      end

      # @!visibility private
      # Thread-safe tracker for login rate limiting. Keys are usernames, values are
      # { failures: Integer, locked_until: Time }.
      def login_rate_limits
        @login_rate_limit_mutex ||= Mutex.new
        @login_rate_limits ||= {}
      end

      # Maximum consecutive failures before lockout.
      LOGIN_MAX_FAILURES = 5
      # Base delay in seconds for exponential backoff.
      LOGIN_BASE_DELAY = 2
      # Maximum number of tracked usernames before cleanup.
      LOGIN_RATE_LIMIT_MAX_ENTRIES = 10_000
      # Entries older than this (seconds) are eligible for cleanup.
      LOGIN_RATE_LIMIT_TTL = 600

      # Checks if a login attempt is allowed for the given username.
      # @raise [Parse::Error::AccountLockoutError] if the account is temporarily locked out.
      def check_login_rate_limit!(username)
        @login_rate_limit_mutex ||= Mutex.new
        @login_rate_limit_mutex.synchronize do
          entry = login_rate_limits[username]
          return unless entry
          if entry[:locked_until] && Time.now < entry[:locked_until]
            wait = (entry[:locked_until] - Time.now).ceil
            raise Parse::Error::AccountLockoutError,
                  "Login rate limited for '#{username}'. Try again in #{wait} seconds."
          end
        end
      end

      # Records a login attempt result and applies exponential backoff on failure.
      def track_login_attempt(username, success)
        @login_rate_limit_mutex ||= Mutex.new
        @login_rate_limit_mutex.synchronize do
          if success
            login_rate_limits.delete(username)
          else
            entry = login_rate_limits[username] || { failures: 0, locked_until: nil }
            entry[:failures] += 1
            if entry[:failures] >= LOGIN_MAX_FAILURES
              delay = LOGIN_BASE_DELAY ** (entry[:failures] - LOGIN_MAX_FAILURES + 1)
              delay = [delay, 300].min # cap at 5 minutes
              entry[:locked_until] = Time.now + delay
            end
            login_rate_limits[username] = entry
          end
          # Periodic cleanup of expired entries to prevent memory leak
          cleanup_login_rate_limits if login_rate_limits.size > LOGIN_RATE_LIMIT_MAX_ENTRIES
        end
      end

      # Removes expired entries from the rate limit tracker.
      # Only deletes entries whose lockout has actually expired past the TTL —
      # never deletes pre-lockout failure counters (which would defeat rate limiting
      # by letting an attacker flood random usernames to trigger cleanup and reset
      # a target's in-progress counter).
      def cleanup_login_rate_limits
        now = Time.now
        login_rate_limits.delete_if do |_username, entry|
          entry[:locked_until] && (now - entry[:locked_until]) > LOGIN_RATE_LIMIT_TTL
        end
      end
    end # Users
  end #API
end #Parse
