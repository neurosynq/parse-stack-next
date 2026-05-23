# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module API
    # Defines the CloudCode interface for the Parse REST API
    module CloudFunctions

      # Call a cloud function.
      # @param name [String] the name of the cloud function.
      # @param body [Hash] the parameters to forward to the function.
      # @param opts [Hash] additional options for the request.
      # @option opts [String] :session_token The session token for authenticated requests.
      # @option opts [String] :master_key Whether to use the master key for this request.
      # @return [Parse::Response]
      def call_function(name, body = {}, opts: {})
        request :post, "functions/#{name}", body: body, opts: opts
      end

      # Trigger a job.
      # @param name [String] the name of the job to trigger.
      # @param body [Hash] the parameters to forward to the job.
      # @param opts [Hash] additional options for the request.
      # @option opts [String] :session_token The session token for authenticated requests.
      # @option opts [String] :master_key Whether to use the master key for this request.
      # @return [Parse::Response]
      def trigger_job(name, body = {}, opts: {})
        request :post, "jobs/#{name}", body: body, opts: opts
      end

      # Call a cloud function with a specific session token.
      # This is a convenience method that ensures the session token is properly passed.
      # @param name [String] the name of the cloud function.
      # @param body [Hash] the parameters to forward to the function.
      # @param session_token [String] the session token for authenticated requests.
      # @return [Parse::Response]
      def call_function_with_session(name, body = {}, session_token)
        opts = {}
        opts[:session_token] = session_token if session_token.present?
        call_function(name, body, opts: opts)
      end

      # Trigger a job with a specific session token.
      # This is a convenience method that ensures the session token is properly passed.
      # @param name [String] the name of the job to trigger.
      # @param body [Hash] the parameters to forward to the job.
      # @param session_token [String] the session token for authenticated requests.
      # @return [Parse::Response]
      def trigger_job_with_session(name, body = {}, session_token)
        opts = {}
        opts[:session_token] = session_token if session_token.present?
        trigger_job(name, body, opts: opts)
      end
    end
  end
end
