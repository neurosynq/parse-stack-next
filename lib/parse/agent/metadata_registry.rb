# encoding: UTF-8
# frozen_string_literal: true

module Parse
  class Agent
    # Registry module that enriches server schemas with local model metadata.
    # Merges class descriptions, property descriptions, and agent-allowed methods
    # from registered Parse::Object models into the schema data returned by the agent.
    #
    # @example Enriching a schema
    #   server_schema = { "className" => "Song", "fields" => { ... } }
    #   enriched = MetadataRegistry.enriched_schema("Song", server_schema)
    #   # enriched now includes :description and :agent_methods if defined
    #
    module MetadataRegistry
      extend self

      # Thread-safe storage for visible classes
      @visible_classes = []
      @visible_mutex = Mutex.new

      # Register a class as visible to agents.
      # @param klass [Class] the model class
      def register_visible_class(klass)
        @visible_mutex.synchronize do
          @visible_classes << klass unless @visible_classes.include?(klass)
        end
      end

      # Get all registered visible classes.
      # @return [Array<Class>]
      def visible_classes
        @visible_mutex.synchronize { @visible_classes.dup }
      end

      # Get visible class names (Parse class names).
      # @return [Array<String>]
      def visible_class_names
        visible_classes.map do |klass|
          klass.respond_to?(:parse_class) ? klass.parse_class : klass.name
        end
      end

      # Check if any classes are registered as visible.
      # @return [Boolean]
      def has_visible_classes?
        @visible_mutex.synchronize { @visible_classes.any? }
      end

      # Filter schemas to only include visible classes.
      # If no classes are marked visible, returns all schemas.
      #
      # @param schemas [Array<Hash>] schemas from Parse Server
      # @return [Array<Hash>] filtered schemas
      def filter_visible_schemas(schemas)
        return schemas unless has_visible_classes?

        visible_names = visible_class_names
        schemas.select { |s| visible_names.include?(s["className"]) }
      end

      # Enrich a server schema with local model metadata.
      #
      # @param class_name [String] the Parse class name
      # @param server_schema [Hash] the schema from Parse Server
      # @param agent_permission [Symbol] the agent's permission level for method filtering
      # @return [Hash] the enriched schema
      def enriched_schema(class_name, server_schema, agent_permission: :readonly)
        klass = find_model_class(class_name)
        return server_schema unless klass&.respond_to?(:has_agent_metadata?) && klass.has_agent_metadata?

        schema = deep_dup(server_schema)

        # Add class description
        if klass.agent_description
          schema["description"] = klass.agent_description
        end

        # Enrich fields with property descriptions
        if schema["fields"] && klass.property_descriptions.any?
          schema["fields"] = enrich_fields(schema["fields"], klass)
        end

        # Add agent-allowed methods (filtered by permission)
        available_methods = klass.agent_methods_for(agent_permission)
        if available_methods.any?
          schema["agent_methods"] = format_methods(available_methods)
        end

        schema
      end

      # Enrich multiple schemas at once.
      #
      # @param server_schemas [Array<Hash>] schemas from Parse Server
      # @param agent_permission [Symbol] the agent's permission level
      # @return [Array<Hash>] enriched schemas
      def enriched_schemas(server_schemas, agent_permission: :readonly)
        server_schemas.map do |schema|
          enriched_schema(schema["className"], schema, agent_permission: agent_permission)
        end
      end

      # Get the class description for a Parse class if registered.
      #
      # @param class_name [String] the Parse class name
      # @return [String, nil] the description or nil
      def class_description(class_name)
        klass = find_model_class(class_name)
        klass&.respond_to?(:agent_description) ? klass.agent_description : nil
      end

      # Get property descriptions for a Parse class if registered.
      #
      # @param class_name [String] the Parse class name
      # @return [Hash<Symbol, String>] field descriptions
      def property_descriptions(class_name)
        klass = find_model_class(class_name)
        return {} unless klass&.respond_to?(:property_descriptions)
        klass.property_descriptions || {}
      end

      # Get agent methods for a Parse class filtered by permission.
      #
      # @param class_name [String] the Parse class name
      # @param agent_permission [Symbol] the agent's permission level
      # @return [Hash<Symbol, Hash>] available methods
      def agent_methods(class_name, agent_permission: :readonly)
        klass = find_model_class(class_name)
        return {} unless klass&.respond_to?(:agent_methods_for)
        klass.agent_methods_for(agent_permission)
      end

      # Check if a model class has agent metadata.
      #
      # @param class_name [String] the Parse class name
      # @return [Boolean]
      def has_metadata?(class_name)
        klass = find_model_class(class_name)
        klass&.respond_to?(:has_agent_metadata?) && klass.has_agent_metadata?
      end

      private

      # Find the Ruby model class for a Parse class name.
      #
      # @param class_name [String] the Parse class name
      # @return [Class, nil] the model class or nil
      def find_model_class(class_name)
        Parse::Model.find_class(class_name)
      rescue NameError
        # Expected - class not registered as a Ruby model
        # This is normal for Parse classes without a corresponding Ruby class
        nil
      rescue StandardError => e
        # Unexpected error - log it for debugging but don't crash
        warn "[Parse::Agent::MetadataRegistry] Error finding model for '#{class_name}': #{e.class} - #{e.message}"
        nil
      end

      # Deep duplicate a hash to avoid modifying the original.
      #
      # @param hash [Hash] the hash to duplicate
      # @return [Hash] the duplicated hash
      def deep_dup(hash)
        return hash unless hash.is_a?(Hash)
        hash.transform_values do |v|
          case v
          when Hash then deep_dup(v)
          when Array then v.map { |e| e.is_a?(Hash) ? deep_dup(e) : e }
          else v
          end
        end
      end

      # Enrich field configs with property descriptions.
      #
      # @param fields [Hash] the fields from server schema
      # @param klass [Class] the model class
      # @return [Hash] enriched fields
      def enrich_fields(fields, klass)
        descriptions = klass.property_descriptions

        fields.transform_keys.with_object({}) do |name, result|
          config = fields[name]
          config = config.is_a?(Hash) ? deep_dup(config) : { "type" => config.to_s }

          # Look up description by both symbol and camelCase versions
          desc = descriptions[name.to_sym] ||
                 descriptions[name.to_s.underscore.to_sym] ||
                 descriptions[name.to_s]

          config["description"] = desc if desc

          result[name] = config
        end
      end

      # Format methods hash for schema output.
      #
      # @param methods [Hash<Symbol, Hash>] the methods to format
      # @return [Array<Hash>] formatted method list
      def format_methods(methods)
        methods.map do |name, info|
          {
            name: name.to_s,
            type: info[:type]&.to_s || "unknown",
            permission: info[:permission]&.to_s || "readonly",
            description: info[:description],
          }.compact
        end
      end
    end
  end
end
