# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module API
    # Defines the Parse Push notification service interface for the Parse REST API
    module Push
      # @!visibility private
      PUSH_PATH = "push"

      # Send a Push notification.
      #
      # Parse Server's `POST /parse/push` endpoint is master-key-only —
      # there is no session-token authorization model for sending pushes,
      # and a no-master-key client cannot use this method. Calling it
      # without master-key credentials returns HTTP 403 from the server;
      # this guard fails closed in the SDK so the deployment's
      # configuration isn't the only line of defense.
      #
      # @param payload [Hash] the payload for the Push notification.
      # @param headers [Hash] additional HTTP headers to send with the request.
      # @param opts [Hash] additional options to pass to the {Parse::Client} request.
      # @return [Parse::Response]
      # @raise [Parse::Error::AuthenticationError] when the client has no master key configured.
      # @see http://docs.parseplatform.org/rest/guide/#sending-pushes Sending Pushes
      def push(payload = {}, headers: {}, **opts)
        unless master_key.is_a?(String) && !master_key.empty?
          raise Parse::Error::AuthenticationError,
                "Parse::API::Push#push requires a master key — push notifications " \
                "have no session-token authorization model in Parse Server"
        end
        opts[:use_master_key] = true unless opts.key?(:use_master_key)
        request :post, PUSH_PATH, body: payload.as_json, headers: headers, opts: opts
      end
    end
  end
end
