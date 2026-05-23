# encoding: UTF-8
# frozen_string_literal: true

require "date"
require "time"

module Parse
  # Direct MongoDB access module for bypassing Parse Server.
  # Provides read-only direct access to MongoDB for performance-critical queries.
  #
  # @example Enable direct MongoDB queries
  #   Parse::MongoDB.configure(
  #     uri: "mongodb://localhost:27017/parse",
  #     enabled: true
  #   )
  #
  # @example Using direct queries
  #   # Returns Parse objects, queried directly from MongoDB
  #   songs = Song.query(:plays.gt => 1000).results_direct
  #   first_song = Song.query(:plays.gt => 1000).first_direct
  #
  # == Field Name Conventions
  #
  # When writing aggregation pipelines for direct MongoDB queries, use MongoDB's native
  # field naming conventions:
  #
  # - *Regular fields*: Use camelCase (e.g., +releaseDate+, +playCount+, +firstName+)
  # - *Pointer fields*: Use +_p_+ prefix (e.g., +_p_author+, +_p_album+)
  # - *Built-in dates*: Use +_created_at+ and +_updated_at+
  # - *Field references*: Use +$fieldName+ syntax (e.g., +$releaseDate+, +$_p_author+)
  #
  # Results are automatically converted to Ruby-friendly format:
  # - Field names converted to snake_case (+totalPlays+ → +total_plays+)
  # - Custom aggregation results wrapped in +AggregationResult+ for method access
  # - Parse documents returned as proper +Parse::Object+ instances
  #
  # @example Aggregation pipeline with MongoDB field names
  #   pipeline = [
  #     { "$match" => { "releaseDate" => { "$lt" => Time.now } } },
  #     { "$group" => { "_id" => "$_p_artist", "totalPlays" => { "$sum" => "$playCount" } } }
  #   ]
  #   results = Song.query.aggregate(pipeline, mongo_direct: true).results
  #
  #   # Results use snake_case and support method access
  #   results.first.total_plays  # => 5000
  #   results.first["totalPlays"] # => 5000 (original key also works)
  #
  # == Date Comparisons
  #
  # MongoDB stores dates in UTC. When comparing dates in aggregation pipelines:
  # - Use Ruby +Time+ objects for comparisons (automatically converted to BSON dates)
  # - Ruby +Date+ objects (without time) are stored as midnight UTC
  # - For accurate date-only comparisons, use +Time.utc(year, month, day)+
  #
  # @example Date comparison in aggregation
  #   # Compare with a specific UTC time
  #   cutoff = Time.utc(2024, 1, 1, 0, 0, 0)
  #   pipeline = [{ "$match" => { "releaseDate" => { "$gte" => cutoff } } }]
  #
  # @example Using the date conversion helper
  #   # Safely convert any date/time to MongoDB-compatible UTC Time
  #   cutoff = Parse::MongoDB.to_mongodb_date(Date.new(2024, 1, 1))  # => Time UTC
  #   cutoff = Parse::MongoDB.to_mongodb_date("2024-01-01")          # => Time UTC
  #   cutoff = Parse::MongoDB.to_mongodb_date(Time.now)              # => Time UTC
  #
  # @note Requires the 'mongo' gem to be installed. Add to your Gemfile:
  #   gem 'mongo', '~> 2.18'
  module MongoDB
    # Error raised when mongo gem is not available
    class GemNotAvailable < StandardError; end

    # Error raised when direct MongoDB is not enabled
    class NotEnabled < StandardError; end

    # Error raised when MongoDB connection fails
    class ConnectionError < StandardError; end

    # Threshold above which `Parse::MongoDB.find` emits a deprecation warning
    # when called without an explicit `:limit` option. A future major release
    # will enforce this as a hard default limit. Callers should pass an
    # explicit `:limit` (including `:limit => 0` for unbounded) to silence the
    # warning.
    DEFAULT_FIND_LIMIT = 1000

    class << self
      # @!attribute [rw] enabled
      #   Feature flag to enable/disable direct MongoDB queries.
      #   @return [Boolean]
      attr_accessor :enabled

      # @!attribute [rw] uri
      #   MongoDB connection URI.
      #   @return [String]
      attr_accessor :uri

      # @!attribute [rw] database
      #   MongoDB database name (extracted from URI or set manually).
      #   @return [String]
      attr_accessor :database

      # @!attribute [r] client
      #   The MongoDB client instance (memoized).
      #   @return [Mongo::Client]
      attr_reader :client

      # Check if the mongo gem is available
      # @return [Boolean] true if mongo gem is loaded
      def gem_available?
        return @gem_available if defined?(@gem_available)
        @gem_available = begin
            require "mongo"
            true
          rescue LoadError
            false
          end
      end

      # Ensure mongo gem is loaded, raise error if not
      # @raise [GemNotAvailable] if mongo gem is not installed
      def require_gem!
        return if gem_available?
        raise GemNotAvailable,
          "The 'mongo' gem is required for direct MongoDB queries. " \
          "Add 'gem \"mongo\"' to your Gemfile and run 'bundle install'."
      end

      # Configure direct MongoDB access
      # @param uri [String] MongoDB connection URI (e.g., "mongodb://localhost:27017/parse")
      # @param enabled [Boolean] whether to enable direct queries (default: true)
      # @param database [String] database name (optional, extracted from URI if not provided)
      # @example
      #   Parse::MongoDB.configure(
      #     uri: "mongodb://user:pass@localhost:27017/parse?authSource=admin",
      #     enabled: true
      #   )
      def configure(uri:, enabled: true, database: nil)
        require_gem!
        @uri = uri
        @enabled = enabled
        @database = database || extract_database_from_uri(uri)
        @client = nil # Reset client on reconfigure
      end

      # Check if direct MongoDB queries are available and enabled
      # @return [Boolean]
      def available?
        gem_available? && enabled? && uri.present?
      end

      # Check if direct queries are enabled
      # @return [Boolean]
      def enabled?
        @enabled == true
      end

      # Get or create the MongoDB client
      # @return [Mongo::Client]
      # @raise [GemNotAvailable] if mongo gem is not installed
      # @raise [NotEnabled] if direct MongoDB is not enabled
      # @raise [ConnectionError] if connection fails
      def client
        require_gem!
        raise NotEnabled, "Direct MongoDB queries are not enabled. Call Parse::MongoDB.configure first." unless available?

        @client ||= begin
            ::Mongo::Client.new(uri)
          rescue => e
            raise ConnectionError, "Failed to connect to MongoDB: #{e.message}"
          end
      end

      # Reset the client connection (useful for testing)
      def reset!
        @client&.close rescue nil
        @client = nil
        @enabled = false
        @uri = nil
        @database = nil
      end

      # Get a MongoDB collection
      # @param name [String] the collection name
      # @return [Mongo::Collection]
      def collection(name)
        client[name]
      end

      # Execute an aggregation pipeline directly on MongoDB
      # @param collection_name [String] the collection name
      # @param pipeline [Array<Hash>] the aggregation pipeline stages
      # @return [Array<Hash>] the raw results from MongoDB
      def aggregate(collection_name, pipeline)
        collection(collection_name).aggregate(pipeline).to_a
      end

      # Execute a find query directly on MongoDB
      # @param collection_name [String] the collection name
      # @param filter [Hash] the query filter
      # @param options [Hash] additional options (limit, skip, sort, projection).
      #   If :limit is omitted and the result exceeds DEFAULT_FIND_LIMIT rows,
      #   a deprecation warning is emitted. A future major release will apply
      #   DEFAULT_FIND_LIMIT as a hard default. Pass `limit: 0` to explicitly
      #   request unbounded behavior without a warning.
      # @return [Array<Hash>] the raw results from MongoDB
      def find(collection_name, filter = {}, **options)
        cursor = collection(collection_name).find(filter)
        if options[:limit] && options[:limit] > 0
          cursor = cursor.limit(options[:limit])
        end
        cursor = cursor.skip(options[:skip]) if options[:skip]
        cursor = cursor.sort(options[:sort]) if options[:sort]
        cursor = cursor.projection(options[:projection]) if options[:projection]
        results = cursor.to_a
        if !options.key?(:limit) && results.size > DEFAULT_FIND_LIMIT
          warn "[DEPRECATION] Parse::MongoDB.find on '#{collection_name}' returned " \
               "#{results.size} rows with no :limit specified. A future release will " \
               "apply a default limit of #{DEFAULT_FIND_LIMIT}. Pass an explicit :limit " \
               "to silence this warning, or :limit => 0 to preserve unbounded behavior."
        end
        results
      end

      # List Atlas Search indexes for a collection
      # Uses the $listSearchIndexes aggregation stage.
      # @param collection_name [String] the collection name
      # @return [Array<Hash>] array of search index definitions
      # @note Requires MongoDB Atlas or local Atlas deployment
      def list_search_indexes(collection_name)
        aggregate(collection_name, [{ "$listSearchIndexes" => {} }])
      end

      # Convert a MongoDB document to Parse REST API format
      # This transforms MongoDB's internal field names to Parse's format:
      # - _id -> objectId
      # - _created_at -> createdAt
      # - _updated_at -> updatedAt
      # - _p_fieldName -> fieldName (as pointer)
      # - _acl -> ACL (with r/w converted to read/write)
      # - Removes other internal fields (_rperm, _wperm, _hashed_password, etc.)
      #
      # @param doc [Hash] the MongoDB document
      # @param class_name [String] the Parse class name
      # @return [Hash] the Parse-formatted hash
      def convert_document_to_parse(doc, class_name = nil)
        return nil unless doc.is_a?(Hash)

        result = {}

        doc.each do |key, value|
          key_str = key.to_s

          case key_str
          when "_id"
            # MongoDB _id becomes Parse objectId
            # Guard against BSON::ObjectId not being defined when mongo gem is not loaded
            result["objectId"] = if defined?(BSON::ObjectId) && value.is_a?(BSON::ObjectId)
                value.to_s
              else
                value
              end
          when "_created_at"
            # MongoDB _created_at becomes Parse createdAt
            result["createdAt"] = convert_date_to_parse(value)
          when "_updated_at"
            # MongoDB _updated_at becomes Parse updatedAt
            result["updatedAt"] = convert_date_to_parse(value)
          when /^_p_(.+)$/
            # Pointer fields: _p_author -> author
            field_name = $1
            result[field_name] = convert_pointer_to_parse(value)
          when "_acl"
            # Convert MongoDB ACL format (r/w) to Parse format (read/write)
            result["ACL"] = convert_acl_to_parse(value)
          when /^_included_(.+)$/
            # Included/resolved pointer field from $lookup - convert embedded document
            # This handles eager loading: _included_artist -> artist (as full object)
            field_name = $1
            if value.is_a?(Hash)
              # Recursively convert the embedded document to Parse format
              result[field_name] = convert_document_to_parse(value)
            elsif value.nil?
              # Preserve nil for unresolved optional relationships
              result[field_name] = nil
            else
              result[field_name] = value
            end
          when /^_include_id_/
            # Skip temporary lookup ID fields (used internally for $lookup)
            next
          when "_rperm", "_wperm", "_hashed_password", "_email_verify_token",
               "_perishable_token", "_tombstone", "_failed_login_count",
               "_account_lockout_expires_at", "_session_token"
            # Skip internal Parse Server fields (not needed since we use _acl)
            next
          when /^_/
            # Skip other internal fields starting with underscore
            next
          else
            # Regular fields - recursively convert nested documents
            result[key_str] = convert_value_to_parse(value)
          end
        end

        # Add className if provided
        result["className"] = class_name if class_name

        result
      end

      # Convert multiple MongoDB documents to Parse format
      # @param docs [Array<Hash>] the MongoDB documents
      # @param class_name [String] the Parse class name
      # @return [Array<Hash>] the Parse-formatted hashes
      def convert_documents_to_parse(docs, class_name = nil)
        docs.map { |doc| convert_document_to_parse(doc, class_name) }
      end

      # Convert a date value to a UTC Time object suitable for MongoDB queries.
      # MongoDB stores all dates in UTC, so this helper ensures consistent date handling
      # when building aggregation pipelines or direct queries.
      #
      # @param value [Date, Time, DateTime, String, nil] the date value to convert
      # @return [Time, nil] a UTC Time object, or nil if value is nil
      # @raise [ArgumentError] if the value cannot be parsed as a date
      #
      # @example Converting different date types
      #   Parse::MongoDB.to_mongodb_date(Date.new(2024, 1, 15))
      #   # => 2024-01-15 00:00:00 UTC
      #
      #   Parse::MongoDB.to_mongodb_date(Time.now)
      #   # => 2024-11-30 12:30:45 UTC (converted to UTC)
      #
      #   Parse::MongoDB.to_mongodb_date("2024-01-15")
      #   # => 2024-01-15 00:00:00 UTC
      #
      #   Parse::MongoDB.to_mongodb_date("2024-01-15T10:30:00Z")
      #   # => 2024-01-15 10:30:00 UTC
      #
      # @example Using in aggregation pipelines
      #   cutoff = Parse::MongoDB.to_mongodb_date(Date.today - 30)
      #   pipeline = [{ "$match" => { "createdAt" => { "$gte" => cutoff } } }]
      #   results = Song.query.aggregate(pipeline, mongo_direct: true).results
      #
      # @example Using with query constraints
      #   # For date comparisons in queries, this ensures UTC consistency
      #   start_date = Parse::MongoDB.to_mongodb_date(params[:start_date])
      #   end_date = Parse::MongoDB.to_mongodb_date(params[:end_date])
      #   songs = Song.query(:release_date.gte => start_date, :release_date.lt => end_date)
      def to_mongodb_date(value)
        return nil if value.nil?

        case value
        when ::Time
          value.utc
        when ::DateTime
          value.to_time.utc
        when ::Date
          # Convert Date to midnight UTC
          ::Time.utc(value.year, value.month, value.day)
        when ::String
          # Parse string dates - try ISO 8601 first, then Date.parse
          begin
            if value =~ /T/
              # ISO 8601 with time component
              ::Time.parse(value).utc
            else
              # Date-only string, convert to midnight UTC
              date = ::Date.parse(value)
              ::Time.utc(date.year, date.month, date.day)
            end
          rescue ::ArgumentError => e
            raise ::ArgumentError, "Cannot parse '#{value}' as a date: #{e.message}"
          end
        when ::Integer
          # Assume Unix timestamp
          ::Time.at(value).utc
        else
          raise ::ArgumentError, "Cannot convert #{value.class} to MongoDB date. " \
                "Expected Date, Time, DateTime, String, or Integer."
        end
      end

      private

      def extract_database_from_uri(uri)
        return nil unless uri
        # Extract database name from MongoDB URI
        # Format: mongodb://[user:pass@]host[:port]/database[?options]
        if uri =~ %r{mongodb(?:\+srv)?://[^/]+/([^?]+)}
          $1
        end
      end

      def convert_date_to_parse(value)
        case value
        when Time, DateTime
          { "__type" => "Date", "iso" => value.utc.iso8601(3) }
        when Date
          { "__type" => "Date", "iso" => value.to_time.utc.iso8601(3) }
        when String
          # Already a string date, wrap in Parse format
          { "__type" => "Date", "iso" => value }
        else
          value
        end
      end

      def convert_pointer_to_parse(value)
        return nil if value.nil?

        if value.is_a?(String) && value.include?("$")
          # Parse pointer format: "ClassName$objectId"
          class_name, object_id = value.split("$", 2)
          {
            "__type" => "Pointer",
            "className" => class_name,
            "objectId" => object_id,
          }
        else
          value
        end
      end

      # Convert MongoDB ACL format to Parse REST API format
      # MongoDB uses short keys: { "*": { r: true, w: false }, "userId": { r: true, w: true } }
      # Parse uses full keys: { "*": { read: true }, "userId": { read: true, write: true } }
      # @param value [Hash] the MongoDB ACL hash
      # @return [Hash] the Parse-formatted ACL hash
      def convert_acl_to_parse(value)
        return nil if value.nil?
        return value unless value.is_a?(Hash)

        result = {}
        value.each do |entity, permissions|
          entity_str = entity.to_s
          next unless permissions.is_a?(Hash)

          parsed_perms = {}
          # Convert r -> read, w -> write
          if permissions["r"] == true || permissions[:r] == true
            parsed_perms["read"] = true
          end
          if permissions["w"] == true || permissions[:w] == true
            parsed_perms["write"] = true
          end
          # Also handle if already in full format
          if permissions["read"] == true || permissions[:read] == true
            parsed_perms["read"] = true
          end
          if permissions["write"] == true || permissions[:write] == true
            parsed_perms["write"] = true
          end

          result[entity_str] = parsed_perms if parsed_perms.any?
        end
        result
      end

      def convert_value_to_parse(value)
        case value
        when Hash
          if value["__type"]
            # Already a Parse type, return as-is
            value
          elsif value[:__type]
            # Symbol keys, convert to string keys
            value.transform_keys(&:to_s)
          else
            # Regular hash, recursively convert
            value.transform_values { |v| convert_value_to_parse(v) }
          end
        when Array
          value.map { |v| convert_value_to_parse(v) }
        when Time, DateTime
          convert_date_to_parse(value)
        when Date
          convert_date_to_parse(value)
        else
          # Handle BSON::ObjectId if mongo gem is loaded
          if defined?(BSON::ObjectId) && value.is_a?(BSON::ObjectId)
            value.to_s
          else
            value
          end
        end
      end
    end

    # Initialize defaults
    @enabled = false
    @uri = nil
    @database = nil
    @client = nil
  end
end
