# encoding: UTF-8
# frozen_string_literal: true

require "active_support"
require "active_support/core_ext"

module Parse
  module API
    # Defines the Batch interface for the Parse REST API
    # @see Parse::BatchOperation
    # @see Array.destroy
    # @see Array.save
    module Batch
      # @note You cannot use batch_requests with {Parse::User} instances that need to
      #  be created.
      # @overload batch_request(requests)
      #  Perform a set of {Parse::Request} instances as a batch operation.
      #  @param requests [Array<Parse::Request>] the set of requests to batch.
      # @overload batch_request(operation)
      #  Submit a batch operation.
      #  @param operation [Parse::BatchOperation] the batch operation.
      # @param opts [Hash] request options for the `POST /batch` call itself,
      #   such as `session_token:` or `use_master_key:`. Parse Server runs
      #   every sub-request under the credentials of this one call (it ignores
      #   per-sub-request headers), so the batch's authority is set here. A
      #   request that names no credentials of its own runs under these.
      # @note Each {Parse::Request}'s own credentials (its `session_token:` /
      #   `use_master_key:` options, its session-token or master-key
      #   suppression headers, and the client it was built for) are honored.
      #   When every request resolves to this client and one set of
      #   credentials, the batch is one call. A transaction that would mix
      #   credentials raises {Parse::BatchOperation::MixedAuthorityError}
      #   before anything is sent. A non-transactional batch with mixed
      #   credentials is sent as one call per set of credentials, through
      #   {Parse::BatchOperation#submit}, with responses in request order.
      #   Elements that are not {Parse::Request} instances are ignored, as
      #   {Parse::BatchOperation#add} ignores them.
      # @return [Array<Parse::Response>] if successful, a set of responses for each operation in the batch.
      # @return [Parse::Response] if an error occurred, the error response.
      # @raise [Parse::BatchOperation::MixedAuthorityError] for a transaction
      #   whose requests name different credentials or another client.
      def batch_request(batch_operations, **opts)
        unless batch_operations.is_a?(Parse::BatchOperation)
          batch_operations = Parse::BatchOperation.new batch_operations
        end
        call_auth = opts.slice(:session_token, :use_master_key, :suppress_master_key)
        groups = batch_operations.authority_groups(self, call_auth)
        if groups.empty?
          return post_batch_operation(batch_operations, opts.except(:suppress_master_key))
        end
        if groups.size == 1 &&
           Parse::BatchOperation.credential_fingerprint(groups.first[:client]) ==
           Parse::BatchOperation.credential_fingerprint(self)
          send_opts = opts.except(:session_token, :use_master_key, :suppress_master_key)
                          .merge(groups.first[:opts])
          return post_batch_operation(batch_operations, send_opts)
        end
        if batch_operations.transaction
          raise Parse::BatchOperation::MixedAuthorityError,
                "A transaction cannot mix requests built for different credentials or " \
                "another client. Parse Server runs a batch under one credential, so it " \
                "cannot honor each request's own. Save these objects in separate transactions."
        end
        # Mixed credentials, not a transaction: send one call per set of
        # credentials, keeping responses in request order.
        routed = Parse::BatchOperation.new(batch_operations.requests)
        routed.client = self
        routed.batch_defaults = call_auth
        routed.submit
      end

      private

      # Send one `POST /batch` call and map its result to responses.
      # @param batch_operations [Parse::BatchOperation]
      # @param opts [Hash] request options for the call.
      def post_batch_operation(batch_operations, opts)
        opts = opts.dup
        headers = nil
        # Sent as the header itself, exactly as a single request carries it:
        # the authentication middleware drops the master key when it is set,
        # even with `use_master_key: true`.
        if opts.delete(:suppress_master_key)
          headers = { Parse::Middleware::Authentication::DISABLE_MASTER_KEY => "true" }
        end
        response = request(:post, "batch", body: batch_operations.as_json, headers: headers, opts: opts)
        return response.batch_responses if response.success? && response.batch?
        return response if response.error?
        # A successful HTTP response whose body is not an array of results
        # cannot be matched to the submitted requests. Report it as a failure
        # rather than as a batch where every write landed.
        Parse::Response.error_response(
          Parse::Response::ERROR_INTERNAL,
          "Malformed batch response: expected an array of results",
          http_status: response.http_status,
        ).tap { |r| r.request = response.request }
      end
    end
  end
end
