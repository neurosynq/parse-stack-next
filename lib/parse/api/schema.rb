# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module API
    # Defines the Schema interface for the Parse REST API
    module Schema
      # @!visibility private
      SCHEMAS_PATH = "schemas"

      # Parse Server serves `/schemas` to the master key only. Every call
      # here therefore asks for the master key explicitly (outside client
      # mode), which also stops an ambient `Parse.with_session` token or a
      # client-bound token from being attached in its place. With a session token attached the request was
      # refused with 403, and callers that cache the class permissions (the
      # CLP scope used by mongo-direct queries) then denied a direct query
      # that the master-keyed client was entitled to run.

      # Get all the schemas for the application.
      # @param opts [Hash] additional options for the request.
      # @return [Parse::Response]
      def schemas(opts = {})
        request_opts = { cache: false }.merge(schema_auth_opts).merge(opts)
        request :get, SCHEMAS_PATH, opts: request_opts
      end

      # Get the schema for a collection.
      # @param className [String] the name of the remote Parse collection.
      # @return [Parse::Response]
      def schema(className)
        safe = Parse::API::PathSegment.identifier!(className, kind: "class name")
        opts = { cache: false }.merge(schema_auth_opts)
        request :get, "#{SCHEMAS_PATH}/#{safe}", opts: opts
      end

      # Create a new collection with the specific schema.
      # @param className [String] the name of the remote Parse collection.
      # @param schema [Hash] the schema hash. This is a specific format specified by
      #  Parse.
      # @return [Parse::Response]
      def create_schema(className, schema)
        safe = Parse::API::PathSegment.identifier!(className, kind: "class name")
        request :post, "#{SCHEMAS_PATH}/#{safe}", body: schema, opts: schema_auth_opts
      end

      # Update the schema for a collection.
      # @param className [String] the name of the remote Parse collection.
      # @param schema [Hash] the schema hash. This is a specific format specified by
      #  Parse.
      # @return [Parse::Response]
      def update_schema(className, schema)
        safe = Parse::API::PathSegment.identifier!(className, kind: "class name")
        request :put, "#{SCHEMAS_PATH}/#{safe}", body: schema, opts: schema_auth_opts
      end

      private

      # Ask for the master key explicitly, except under `Parse.client_mode`,
      # whose contract is that the SDK never sends the master key on its own
      # initiative. A client with no master key configured sends none either
      # way.
      # @!visibility private
      def schema_auth_opts
        { use_master_key: !Parse.client_mode }
      end
    end #Schema
  end #API
end
