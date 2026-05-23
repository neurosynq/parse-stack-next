# encoding: UTF-8
# frozen_string_literal: true

module Parse
  class Agent
    # The ResultFormatter transforms Parse API responses into
    # LLM-friendly formats that are easy to understand and process.
    #
    # It provides consistent structure, human-readable type descriptions,
    # and truncates large results to fit context windows.
    #
    module ResultFormatter
      extend self

      # Maximum number of results to include in output
      MAX_RESULTS_DISPLAY = 50

      # Parse field type mappings for human-readable output
      TYPE_NAMES = {
        "String" => "string",
        "Number" => "number",
        "Boolean" => "boolean",
        "Date" => "date/time",
        "Object" => "object (JSON)",
        "Array" => "array",
        "GeoPoint" => "geo location",
        "File" => "file",
        "Pointer" => "pointer (reference)",
        "Relation" => "relation (many-to-many)",
        "Bytes" => "binary data",
        "Polygon" => "polygon (geo shape)",
        "ACL" => "access control list",
      }.freeze

      # Format multiple schemas for display (compact summary)
      # Returns class names grouped by type for efficient token usage.
      # Use get_schema for detailed field info on specific classes.
      #
      # @param schemas [Array<Hash>] array of schema objects from Parse (enriched with metadata)
      # @return [Hash] formatted schema summary
      def format_schemas(schemas)
        built_in = []
        custom = []

        schemas.each do |schema|
          class_name = schema["className"]
          fields = schema["fields"] || {}
          agent_methods = schema["agent_methods"] || []

          info = {
            name: class_name,
            fields: fields.size - 4, # exclude objectId, createdAt, updatedAt, ACL
          }

          # Include description if present (compact)
          info[:desc] = schema["description"] if schema["description"]

          # Include agent methods count if any
          info[:methods] = agent_methods.size if agent_methods.any?

          if class_name.start_with?("_")
            built_in << info
          else
            custom << info
          end
        end

        {
          total: schemas.size,
          note: "Use get_schema(class_name) for detailed field info",
          built_in: built_in,
          custom: custom,
        }
      end

      # Format a single schema for detailed display
      #
      # @param schema [Hash] schema object from Parse (enriched with metadata)
      # @return [Hash] formatted schema details
      def format_schema(schema)
        class_name = schema["className"]
        fields = schema["fields"] || {}
        indexes = schema["indexes"] || {}
        clp = schema["classLevelPermissions"] || {}
        agent_methods = schema["agent_methods"] || []

        result = {
          class_name: class_name,
          type: class_type(class_name),
        }

        # Include class description if present
        result[:description] = schema["description"] if schema["description"]

        result[:fields] = format_fields_detailed(fields)
        result[:indexes] = format_indexes(indexes)
        result[:permissions] = format_clp(clp)

        # Include agent methods if any
        result[:agent_methods] = agent_methods if agent_methods.any?

        result
      end

      # Format query results
      #
      # @param class_name [String] the class that was queried
      # @param results [Array<Hash>] array of result objects
      # @param limit [Integer] the limit that was requested
      # @param skip [Integer] the skip offset
      # @return [Hash] formatted results
      def format_query_results(class_name, results, limit:, skip:)
        total = results.size
        truncated = total > MAX_RESULTS_DISPLAY

        displayed_results = if truncated
            results.first(MAX_RESULTS_DISPLAY)
          else
            results
          end

        {
          class_name: class_name,
          result_count: total,
          pagination: {
            limit: limit,
            skip: skip,
            has_more: total >= limit,
          },
          truncated: truncated,
          truncated_note: truncated ? "Showing first #{MAX_RESULTS_DISPLAY} of #{total} results" : nil,
          results: displayed_results.map { |obj| simplify_object(obj) },
        }.compact
      end

      # Format a single object
      #
      # @param class_name [String] the class name
      # @param object [Hash] the object data
      # @return [Hash] formatted object
      def format_object(class_name, object)
        {
          class_name: class_name,
          object_id: object["objectId"],
          created_at: object["createdAt"],
          updated_at: object["updatedAt"],
          object: simplify_object(object),
        }
      end

      private

      # Determine the type of class (built-in vs custom)
      def class_type(class_name)
        case class_name
        when "_User" then "built-in: User accounts"
        when "_Role" then "built-in: Access roles"
        when "_Session" then "built-in: User sessions"
        when "_Installation" then "built-in: Device installations"
        when "_Product" then "built-in: In-app purchases"
        when "_Audience" then "built-in: Push audiences"
        else "custom"
        end
      end

      # Format field list for summary view
      def format_field_list(fields)
        # Exclude default Parse fields for cleaner output
        default_fields = %w[objectId createdAt updatedAt ACL]

        fields.reject { |name, _| default_fields.include?(name) }
              .map { |name, config| "#{name} (#{type_name(config)})" }
      end

      # Format fields with full details
      def format_fields_detailed(fields)
        fields.map do |name, config|
          # Handle both Hash configs and simple type strings
          config = { "type" => config.to_s } unless config.is_a?(Hash)

          field_info = {
            name: name,
            type: type_name(config),
            required: config["required"] || false,
          }

          # Add field description if present (from agent metadata)
          if config["description"]
            field_info[:description] = config["description"]
          end

          # Add pointer target class if applicable
          if config["type"] == "Pointer"
            field_info[:target_class] = config["targetClass"]
          elsif config["type"] == "Relation"
            field_info[:target_class] = config["targetClass"]
          end

          # Add default value if present
          if config.key?("defaultValue")
            field_info[:default] = config["defaultValue"]
          end

          field_info
        end
      end

      # Format indexes for display
      def format_indexes(indexes)
        indexes.map do |name, definition|
          {
            name: name,
            fields: definition.keys,
            unique: name.include?("unique") || definition.values.include?("unique"),
          }
        end
      end

      # Format class-level permissions
      def format_clp(clp)
        return {} if clp.empty?

        clp.transform_values do |permission|
          case permission
          when Hash
            permission.keys.map do |key|
              case key
              when "*" then "public"
              when /^role:/ then key
              else "user:#{key}"
              end
            end
          when true then ["public"]
          when false then ["none"]
          else [permission.to_s]
          end
        end
      end

      # Get human-readable type name
      def type_name(config)
        type = config["type"]
        base_name = TYPE_NAMES[type] || type.to_s.downcase

        case type
        when "Pointer"
          "#{base_name} → #{config["targetClass"]}"
        when "Relation"
          "#{base_name} → #{config["targetClass"]}"
        else
          base_name
        end
      end

      # Simplify an object for display (resolve __type fields)
      def simplify_object(obj)
        return obj unless obj.is_a?(Hash)

        obj.transform_values do |value|
          simplify_value(value)
        end
      end

      # Simplify a single value
      def simplify_value(value)
        case value
        when Hash
          simplify_typed_value(value)
        when Array
          value.map { |v| simplify_value(v) }
        else
          value
        end
      end

      # Simplify Parse typed values (__type fields)
      def simplify_typed_value(hash)
        type = hash["__type"]

        case type
        when "Date"
          hash["iso"]
        when "Pointer"
          {
            _type: "Pointer",
            class: hash["className"],
            id: hash["objectId"],
          }
        when "File"
          {
            _type: "File",
            name: hash["name"],
            url: hash["url"],
          }
        when "GeoPoint"
          {
            _type: "GeoPoint",
            latitude: hash["latitude"],
            longitude: hash["longitude"],
          }
        when "Bytes"
          {
            _type: "Bytes",
            base64: hash["base64"]&.slice(0, 50)&.then { |s| "#{s}..." },
          }
        when "Relation"
          {
            _type: "Relation",
            class: hash["className"],
          }
        else
          # Regular object or unknown type - recurse
          simplify_object(hash)
        end
      end
    end
  end
end
