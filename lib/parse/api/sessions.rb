# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module API
    # Defines the Session class interface for the Parse REST API
    module Sessions
      # @!visibility private
      SESSION_PATH_PREFIX = "sessions"

      # Fetch a session record for a given session token.
      # @param session_token [String] an active session token.
      # @param opts [Hash] additional options to pass to the {Parse::Client} request.
      # @return [Parse::Response]
      def fetch_session(session_token, **opts)
        # The positional token is passed as the explicit per-call token so an
        # ambient `Parse.with_session` token or a client-bound token cannot
        # replace it and return another user's session.
        session_token = session_token.session_token if session_token.respond_to?(:session_token)
        opts = opts.merge({ use_master_key: false, cache: false, session_token: session_token.to_s })
        headers = { Parse::Protocol::SESSION_TOKEN => session_token.to_s }
        response = request :get, "#{SESSION_PATH_PREFIX}/me", headers: headers, opts: opts
        response.parse_class = Parse::Model::CLASS_SESSION
        response
      end
    end
  end
end
