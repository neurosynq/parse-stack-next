# encoding: UTF-8
# frozen_string_literal: true

require "active_support"
require "active_support/core_ext"

module Parse
  module API
    # Defines the Parse Files interface for the Parse REST API
    module Files
      # @!visibility private
      FILES_PATH = "files"

      # Upload and create a Parse file.
      # @param fileName [String] the basename of the file.
      # @param data [Hash] the data related to this file.
      # @param content_type [String] the mime-type of the file.
      # @param opts [Hash] additional options forwarded to {Parse::Client#request}
      #   (e.g. :session_token, :use_master_key). When the SDK is running in
      #   client mode against a Parse Server with `fileUpload.enableForAuthenticatedUser`
      #   on, a session_token is required for the upload to be accepted.
      # @return [Parse::Response]
      def create_file(fileName, data = {}, content_type = nil, **opts)
        safe = Parse::API::PathSegment.file!(fileName, kind: "file name")
        headers = {}
        headers.merge!({ Parse::Protocol::CONTENT_TYPE => content_type.to_s }) if content_type.present?
        response = request :post, "#{FILES_PATH}/#{safe}", body: data, headers: headers, opts: opts
        response.parse_class = Parse::Model::TYPE_FILE
        response
      end
    end
  end
end
