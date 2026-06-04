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

      # Keys stripped from every simplified data object before it reaches
      # the LLM. The raw `ACL` map (per-role / per-user read/write bits) is
      # operationally useless to a model reasoning over row data — the
      # agent's effective read/write authority is enforced server-side
      # regardless of what ACL a row carries — so surfacing it is pure
      # token overhead plus a minor disclosure of role/user identifiers.
      # Applied recursively (nested included records too).
      DROPPED_OBJECT_KEYS = %w[ACL].freeze

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

          # Subtract the four system fields (objectId, createdAt, updatedAt,
          # ACL) when reporting a "user-meaningful" count, but never let the
          # subtraction go negative — the allowlist filter in enriched_schema
          # may have already trimmed system fields out.
          info = {
            name: class_name,
            fields: [fields.size - 4, 0].max,
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

        # Include analytics usage hint if present (separate from description)
        result[:usage] = schema["usage"] if schema["usage"]

        result[:fields] = format_fields_detailed(fields)
        result[:indexes] = format_indexes(indexes)
        result[:permissions] = format_clp(clp)

        # Include agent methods if any
        result[:agent_methods] = agent_methods if agent_methods.any?

        # Include the canonical "valid state" filter when declared. Lets
        # callers that opt out of the default `apply_canonical_filter`
        # behavior reproduce the predicate manually in their where:.
        if schema["canonical_filter"].is_a?(Hash) && schema["canonical_filter"].any?
          result[:canonical_filter] = schema["canonical_filter"]
        end

        # Echo the wire-format agent_fields allowlist when declared. The
        # allowlist already filters `result[:fields]` by omission, but the
        # explicit list answers "what may I write in `keys:` for this
        # class" without forcing the consumer to scan the fields array.
        # Storage-form columns (`_p_*`) and other Parse-internal
        # underscored columns are never addressable through agent tools.
        if schema["agent_fields"].is_a?(Array) && schema["agent_fields"].any?
          result[:agent_fields] = schema["agent_fields"]
        end

        # Echo the narrower join projection (wire-format) when declared.
        # Tells consumers "when this class is included on another class's
        # query, these are the fields you'll see."
        if schema["agent_join_fields"].is_a?(Array) && schema["agent_join_fields"].any?
          result[:agent_join_fields] = schema["agent_join_fields"]
        end

        # Include relationship edges if any (set by MetadataRegistry)
        if schema["relations"].is_a?(Hash) &&
           (schema["relations"]["outgoing"].to_a.any? || schema["relations"]["incoming"].to_a.any?)
          result[:relations] = schema["relations"]
        end

        result
      end

      # Format query results
      #
      # @param class_name [String] the class that was queried
      # @param results [Array<Hash>] array of result objects
      # @param limit [Integer] the limit that was requested
      # @param skip [Integer] the skip offset
      # @param where [Hash, nil] query constraints from the original call
      # @param keys [Array<String>, nil] field projection from the original call
      # @param order [String, nil] sort field from the original call
      # @param include [Array<String>, nil] pointer includes from the original call
      # @return [Hash] formatted results
      def format_query_results(class_name, results, limit:, skip:,
                               where: nil, keys: nil, order: nil, include: nil,
                               truncated_include_fields: nil)
        total = results.size
        truncated = total > MAX_RESULTS_DISPLAY
        has_more = total >= limit

        displayed_results = if truncated
            results.first(MAX_RESULTS_DISPLAY)
          else
            results
          end

        next_call = if has_more
            next_args = {
              class_name: class_name,
              limit: limit,
              skip: skip + limit,
              where: where,
              keys: keys,
              order: order,
              include: include,
            }.compact
            { tool: "query_class", arguments: next_args }
          end

        # Surface keys-on-include auto-projection metadata so the LLM
        # can see which joins were narrowed and re-ask with explicit
        # dotted paths (`keys: ["user.iconImage"]`) if it needs fields
        # that were dropped. Suppress the key when nothing was auto-
        # projected — keeps the envelope minimal for the common case.
        truncated_includes_payload =
          if truncated_include_fields && !truncated_include_fields.empty?
            truncated_include_fields.transform_values { |meta| meta[:dropped] }.compact
          end

        {
          class_name: class_name,
          result_count: total,
          pagination: {
            limit: limit,
            skip: skip,
            has_more: has_more,
          },
          truncated: truncated,
          truncated_note: truncated ? "Showing first #{MAX_RESULTS_DISPLAY} of #{total} results" : nil,
          truncated_include_fields: truncated_includes_payload,
          next_call: next_call,
          results: displayed_results.map { |obj| simplify_object(obj) },
        }.compact
      end

      # Format a single object
      #
      # @param class_name [String] the class name
      # @param object [Hash] the object data
      # @param truncated_include_fields [Hash, nil] map of pointer-name => {dropped:, source:}
      #   when keys-on-include auto-projection narrowed any joined record.
      # @return [Hash] formatted object
      def format_object(class_name, object, truncated_include_fields: nil)
        envelope = {
          class_name: class_name,
          object_id: object["objectId"],
          created_at: object["createdAt"],
          updated_at: object["updatedAt"],
          object: simplify_object(object),
        }
        if truncated_include_fields && !truncated_include_fields.empty?
          envelope[:truncated_include_fields] =
            truncated_include_fields.transform_values { |meta| meta[:dropped] }
        end
        envelope
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

          # Per-value enum documentation declared via `property … _enum:`.
          # Surfaced as a list of {value, description} objects so an LLM
          # composing a `where:` constraint can pick the right value
          # without re-querying or guessing from the bare value names.
          if config["allowed_values"].is_a?(Array) && config["allowed_values"].any?
            field_info[:allowed_values] = config["allowed_values"]
          end

          # Surface the agent_large_fields annotation so an LLM client can
          # project this field away in its first query rather than hitting
          # the dispatcher's response-size cap.
          if config["large_field"]
            field_info[:large_field] = true
          end

          # Add pointer/relation target class if applicable. Suppress
          # `target_class` when the target is a hidden class — and for
          # Pointer fields, collapse `query_hint` to the generic
          # `<targetClass>` placeholder. Resolve via MetadataRegistry
          # when available; pass through when the registry is unloaded
          # (pure-unit contexts).
          if config["type"] == "Pointer"
            target = config["targetClass"]
            if target_class_hidden?(target)
              field_info[:query_hint] = pointer_query_hint(name, nil)
            else
              field_info[:target_class] = target
              field_info[:query_hint] = pointer_query_hint(name, target)
            end
          elsif config["type"] == "Relation"
            target = config["targetClass"]
            field_info[:target_class] = target unless target_class_hidden?(target)
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

      # True when MetadataRegistry positively reports `target` as
      # hidden. Falsy when the registry is unloaded (pure-unit
      # contexts) — preserves the historical "show the target" behavior
      # for callers that don't load the agent layer.
      def target_class_hidden?(target)
        target &&
          defined?(Parse::Agent::MetadataRegistry) &&
          Parse::Agent::MetadataRegistry.respond_to?(:hidden?) &&
          Parse::Agent::MetadataRegistry.hidden?(target)
      end

      # Build a one-line value-shape hint for a pointer field. Surfaced
      # in get_schema output so an LLM composing a where: constraint
      # against a pointer column knows the accepted shapes without
      # having to query a sample row first. Mirrors the shapes the
      # SDK actually accepts in convert_constraints_for_aggregation
      # (mongo-direct) and the REST find_objects path.
      def pointer_query_hint(field_name, target_class)
        target = target_class || "<targetClass>"
        equality = "{ #{field_name.inspect} => \"<objectId>\" } or " \
                   "{ #{field_name.inspect} => { \"__type\" => \"Pointer\", " \
                   "\"className\" => #{target.inspect}, \"objectId\" => \"<id>\" } }"
        in_shape = "{ #{field_name.inspect} => { \"$in\" => [\"<id1>\", \"<id2>\"] } } " \
                   "(bare objectIds; the SDK normalizes against the pointer storage shape)"
        "Pointer to #{target}. Equality: #{equality}. $in/$nin: #{in_shape}."
      end

      # Simplify an object for display (resolve __type fields). Strips the
      # raw ACL map (see {DROPPED_OBJECT_KEYS}). Public so the query/get/
      # atlas tool envelopes can route their rows through the same
      # normalization query_class already uses.
      def simplify_object(obj)
        return obj unless obj.is_a?(Hash)

        obj.each_with_object({}) do |(key, value), acc|
          next if DROPPED_OBJECT_KEYS.include?(key.to_s)

          acc[key] = simplify_value(value)
        end
      end
      public :simplify_object

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
        when "Polygon"
          {
            _type: "Polygon",
            coordinates: hash["coordinates"],
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
