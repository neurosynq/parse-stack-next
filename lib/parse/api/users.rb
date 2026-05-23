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
      REQUEST_PASSWORD_RESET = "requestPasswordReset"

      # Fetch a {Parse::User} for a given objectId.
      # @param id [String] the user objectid
      # @param opts [Hash] additional options to pass to the {Parse::Client} request.
      # @param headers [Hash] additional HTTP headers to send with the request.
      # @return [Parse::Response]
      def fetch_user(id, headers: {}, **opts)
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
      # @param opts [Hash] additional options to pass to the {Parse::Client} request.
      # @param headers [Hash] additional HTTP headers to send with the request.
      # @return [Parse::Response]
      def current_user(session_token, headers: {}, **opts)
        headers.merge!({ Parse::Protocol::SESSION_TOKEN => session_token })
        response = request :get, "#{USER_PATH_PREFIX}/me", headers: headers, opts: opts
        response.parse_class = Parse::Model::CLASS_USER
        response
      end

      # Create a new user.
      # @param body [Hash] a hash of values related to your _User schema.
      # @param opts [Hash] additional options to pass to the {Parse::Client} request.
      # @param headers [Hash] additional HTTP headers to send with the request.
      # @return [Parse::Response]
      def create_user(body, headers: {}, **opts)
        headers.merge!({ Parse::Protocol::REVOCABLE_SESSION => "1" })
        if opts[:session_token].present?
          headers.merge!({ Parse::Protocol::SESSION_TOKEN => opts[:session_token] })
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
        response = request :put, "#{USER_PATH_PREFIX}/#{id}", body: body, opts: opts
        response.parse_class = Parse::Model::CLASS_USER
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
        update_user(id, body, opts)
      end

      # Delete a {Parse::User} record given an objectId.
      # @param id [String] the Parse user objectId.
      # @param opts [Hash] additional options to pass to the {Parse::Client} request.
      # @param headers [Hash] additional HTTP headers to send with the request.
      # @return [Parse::Response]
      def delete_user(id, headers: {}, **opts)
        request :delete, "#{USER_PATH_PREFIX}/#{id}", headers: headers, opts: opts
      end

      # Request a password reset for a registered email.
      # @param email [String] the Parse user email.
      # @param opts [Hash] additional options to pass to the {Parse::Client} request.
      # @param headers [Hash] additional HTTP headers to send with the request.
      # @return [Parse::Response]
      def request_password_reset(email, headers: {}, **opts)
        body = { email: email }
        request :post, REQUEST_PASSWORD_RESET, body: body, opts: opts, headers: headers
      end

      # Login a user. Implements client-side rate limiting with exponential
      # backoff after repeated failures to mitigate brute force attacks.
      # @param username [String] the Parse user username.
      # @param password [String] the Parse user's associated password.
      # @param headers [Hash] additional HTTP headers to send with the request.
      # @param opts [Hash] additional options to pass to the {Parse::Client} request.
      # @return [Parse::Response]
      def login(username, password, headers: {}, **opts)
        check_login_rate_limit!(username)
        body = { username: username, password: password }
        headers.merge!({ Parse::Protocol::REVOCABLE_SESSION => "1" })
        response = request :post, LOGIN_PATH, body: body, headers: headers, opts: opts
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
        headers.merge!({ Parse::Protocol::REVOCABLE_SESSION => "1" })
        response = request :post, LOGIN_PATH, body: body, headers: headers, opts: opts
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
        headers.merge!({ Parse::Protocol::SESSION_TOKEN => session_token })
        opts.merge!({ use_master_key: false, session_token: session_token })
        request :post, LOGOUT_PATH, headers: headers, opts: opts
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
        create_user(body, opts)
      end
      private

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
      # @raise [RuntimeError] if the account is temporarily locked out.
      def check_login_rate_limit!(username)
        @login_rate_limit_mutex ||= Mutex.new
        @login_rate_limit_mutex.synchronize do
          entry = login_rate_limits[username]
          return unless entry
          if entry[:locked_until] && Time.now < entry[:locked_until]
            wait = (entry[:locked_until] - Time.now).ceil
            raise "Login rate limited for '#{username}'. Try again in #{wait} seconds."
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
              delay = LOGIN_BASE_DELAY**(entry[:failures] - LOGIN_MAX_FAILURES + 1)
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
