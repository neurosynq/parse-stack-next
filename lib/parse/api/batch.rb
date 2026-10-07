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
      #   per-sub-request headers), so the batch's authority is set here.
      # @return [Array<Parse::Response>] if successful, a set of responses for each operation in the batch.
      # @return [Parse::Response] if an error occurred, the error response.
      def batch_request(batch_operations, **opts)
        unless batch_operations.is_a?(Parse::BatchOperation)
          batch_operations = Parse::BatchOperation.new batch_operations
        end
        response = request(:post, "batch", body: batch_operations.as_json, opts: opts)
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
