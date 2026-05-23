# encoding: UTF-8
# frozen_string_literal: true

require "timeout"

module Parse
  class Agent
    # The Tools module contains all the executable tool implementations
    # for the Parse Agent. Each tool is a class method that takes an agent
    # instance and keyword arguments.
    #
    # Tools are divided into categories:
    # - **Schema tools**: get_all_schemas, get_schema
    # - **Query tools**: query_class, count_objects, get_object, get_sample_objects
    # - **Analysis tools**: aggregate, explain_query
    #
    module Tools
      extend self

      # Methods that are dangerous and should never be invoked via tools.
      # Defined here (rather than MCPServer) so it's always available.
      BLOCKED_METHODS = %w[
        eval exec system ` send __send__ public_send instance_eval class_eval
        module_eval define_method remove_method undef_method
        open fork spawn syscall load require require_relative
        const_get const_set remove_const method binding
        instance_variable_set instance_variable_get
      ].freeze

      # Default timeout for tool operations (seconds)
      DEFAULT_TIMEOUT = 30

      # Per-tool timeout overrides for long-running operations
      TOOL_TIMEOUTS = {
        aggregate: 60,
        query_class: 30,
        explain_query: 30,
        call_method: 60,
        get_all_schemas: 15,
        get_schema: 10,
        count_objects: 20,
        get_object: 10,
        get_sample_objects: 15,
      }.freeze

      # Tool definitions in OpenAI function calling format
      # Optimized for token efficiency - LLMs understand from context
      TOOL_DEFINITIONS = {
        get_all_schemas: {
          name: "get_all_schemas",
          description: "List all classes with field counts",
          parameters: { type: "object", properties: {}, required: [] },
        },

        get_schema: {
          name: "get_schema",
          description: "Get class fields and types",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string" },
            },
            required: ["class_name"],
          },
        },

        query_class: {
          name: "query_class",
          description: "Query objects with constraints",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              where: { type: "object" },
              limit: { type: "integer" },
              skip: { type: "integer" },
              order: { type: "string" },
              keys: { type: "array", items: { type: "string" } },
              include: { type: "array", items: { type: "string" } },
            },
            required: ["class_name"],
          },
        },

        count_objects: {
          name: "count_objects",
          description: "Count matching objects",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              where: { type: "object" },
            },
            required: ["class_name"],
          },
        },

        get_object: {
          name: "get_object",
          description: "Fetch by objectId",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              object_id: { type: "string" },
              include: { type: "array", items: { type: "string" } },
            },
            required: ["class_name", "object_id"],
          },
        },

        get_sample_objects: {
          name: "get_sample_objects",
          description: "Sample objects from class",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              limit: { type: "integer" },
            },
            required: ["class_name"],
          },
        },

        aggregate: {
          name: "aggregate",
          description: "MongoDB aggregation pipeline",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              pipeline: { type: "array", items: { type: "object" } },
            },
            required: ["class_name", "pipeline"],
          },
        },

        explain_query: {
          name: "explain_query",
          description: "Query execution plan",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              where: { type: "object" },
            },
            required: ["class_name"],
          },
        },

        call_method: {
          name: "call_method",
          description: "Call agent-allowed method",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              method_name: { type: "string" },
              object_id: { type: "string" },
              arguments: { type: "object" },
            },
            required: ["class_name", "method_name"],
          },
        },
      }.freeze

      # Get tool definitions for allowed tools
      #
      # @param allowed_tools [Array<Symbol>] list of tool names to include
      # @param format [Symbol] output format (:openai or :mcp)
      # @return [Array<Hash>] tool definitions
      def definitions(allowed_tools, format: :openai)
        defs = allowed_tools.filter_map do |tool_name|
          TOOL_DEFINITIONS[tool_name]
        end

        case format
        when :mcp
          defs.map { |d| to_mcp_format(d) }
        else
          defs.map { |d| { type: "function", function: d } }
        end
      end

      # Convert OpenAI format to MCP format
      def to_mcp_format(definition)
        {
          name: definition[:name],
          description: definition[:description],
          inputSchema: definition[:parameters],
        }
      end

      # ============================================================
      # SCHEMA TOOLS
      # ============================================================

      # Get all schemas from the Parse server
      #
      # @param agent [Parse::Agent] the agent instance
      # @return [Hash] formatted schema information
      def get_all_schemas(agent, **_kwargs)
        response = agent.client.schemas(agent.request_opts)

        unless response.success?
          raise "Failed to fetch schemas: #{response.error}"
        end

        # response.result is already the results array (Parse::Response extracts it)
        schemas = response.results

        # Enrich with local model metadata (descriptions, agent methods)
        enriched = MetadataRegistry.enriched_schemas(schemas, agent_permission: agent.permissions)

        ResultFormatter.format_schemas(enriched)
      end

      # Get schema for a specific class
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] the Parse class name
      # @return [Hash] formatted schema information
      def get_schema(agent, class_name:, **_kwargs)
        response = agent.client.schema(class_name)

        unless response.success?
          raise "Failed to fetch schema for '#{class_name}': #{response.error}"
        end

        # Enrich with local model metadata (descriptions, agent methods)
        enriched = MetadataRegistry.enriched_schema(class_name, response.result, agent_permission: agent.permissions)

        ResultFormatter.format_schema(enriched)
      end

      # ============================================================
      # QUERY TOOLS
      # ============================================================

      # Query objects from a Parse class
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] the Parse class name
      # @param where [Hash] query constraints
      # @param limit [Integer] max results (default 100)
      # @param skip [Integer] pagination offset
      # @param order [String] sort field (prefix with '-' for desc)
      # @param keys [Array<String>] fields to select
      # @param include [Array<String>] pointer fields to include
      # @return [Hash] query results
      # @raise [ConstraintTranslator::ConstraintSecurityError] if blocked operators are used
      def query_class(agent, class_name:, where: nil, limit: nil, skip: nil,
                             order: nil, keys: nil, include: nil, **_kwargs)
        limit = [limit || Agent::DEFAULT_LIMIT, Agent::MAX_LIMIT].min

        # Build query hash
        query = {}
        query[:limit] = limit
        query[:skip] = skip if skip && skip > 0
        query[:order] = order if order
        query[:keys] = keys.join(",") if keys&.any?
        query[:include] = include.join(",") if include&.any?

        # SECURITY: Constraint validation happens in ConstraintTranslator.translate
        # This blocks dangerous operators like $where, $function
        if where && !where.empty?
          query[:where] = ConstraintTranslator.translate(where).to_json
        end

        with_timeout(:query_class) do
          response = agent.client.find_objects(class_name, query, **agent.request_opts)

          unless response.success?
            raise "Query failed: #{response.error}"
          end

          # response.results returns the array (Parse::Response extracts it)
          results = response.results
          ResultFormatter.format_query_results(class_name, results, limit: limit, skip: skip || 0)
        end
      end

      # Count objects in a Parse class
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] the Parse class name
      # @param where [Hash] query constraints
      # @return [Hash] count result
      def count_objects(agent, class_name:, where: nil, **_kwargs)
        query = { limit: 0, count: 1 }

        if where && !where.empty?
          query[:where] = ConstraintTranslator.translate(where).to_json
        end

        response = agent.client.find_objects(class_name, query, **agent.request_opts)

        unless response.success?
          raise "Count failed: #{response.error}"
        end

        {
          class_name: class_name,
          count: response.count,
          constraints: where || {},
        }
      end

      # Get a single object by ID
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] the Parse class name
      # @param object_id [String] the objectId
      # @param include [Array<String>] pointer fields to include
      # @return [Hash] the object data
      def get_object(agent, class_name:, object_id:, include: nil, **_kwargs)
        query = {}
        query[:include] = include.join(",") if include&.any?

        response = agent.client.fetch_object(class_name, object_id, query: query, **agent.request_opts)

        unless response.success?
          if response.object_not_found?
            raise "Object not found: #{class_name}##{object_id}"
          end
          raise "Fetch failed: #{response.error}"
        end

        ResultFormatter.format_object(class_name, response.result)
      end

      # Get sample objects from a class
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] the Parse class name
      # @param limit [Integer] number of samples (default 5, max 20)
      # @return [Hash] sample objects
      def get_sample_objects(agent, class_name:, limit: nil, **_kwargs)
        limit = [limit || 5, 20].min

        query = {
          limit: limit,
          order: "-createdAt",
        }

        response = agent.client.find_objects(class_name, query, **agent.request_opts)

        unless response.success?
          raise "Sample query failed: #{response.error}"
        end

        # response.results returns the array (Parse::Response extracts it)
        results = response.results
        {
          class_name: class_name,
          sample_count: results.size,
          samples: results.map { |obj| ResultFormatter.format_object(class_name, obj)[:object] },
          note: "These are the #{results.size} most recently created objects",
        }
      end

      # ============================================================
      # ANALYSIS TOOLS
      # ============================================================

      # Run an aggregation pipeline
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] the Parse class name
      # @param pipeline [Array<Hash>] MongoDB aggregation pipeline
      # @return [Hash] aggregation results
      # @raise [PipelineValidator::PipelineSecurityError] if pipeline contains blocked stages
      def aggregate(agent, class_name:, pipeline:, **_kwargs)
        # SECURITY: Validate pipeline BEFORE execution
        # This blocks dangerous stages like $out, $merge, $function
        PipelineValidator.validate!(pipeline)

        with_timeout(:aggregate) do
          response = agent.client.aggregate_pipeline(class_name, pipeline, **agent.request_opts)

          unless response.success?
            raise "Aggregation failed: #{response.error}"
          end

          # response.results returns the array (Parse::Response extracts it)
          results = response.results
          {
            class_name: class_name,
            pipeline_stages: pipeline.size,
            result_count: results.size,
            results: results,
          }
        end
      end

      # Explain a query's execution plan
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] the Parse class name
      # @param where [Hash] query constraints
      # @return [Hash] query explanation
      def explain_query(agent, class_name:, where: nil, **_kwargs)
        query = { explain: true, limit: 1 }

        if where && !where.empty?
          query[:where] = ConstraintTranslator.translate(where).to_json
        end

        response = agent.client.find_objects(class_name, query, **agent.request_opts)

        unless response.success?
          raise "Explain failed: #{response.error}"
        end

        {
          class_name: class_name,
          constraints: where || {},
          explanation: response.result,
        }
      end

      # ============================================================
      # METHOD TOOLS
      # ============================================================

      # Call an agent-allowed method on a Parse class
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] the Parse class name
      # @param method_name [String] the name of the method to call
      # @param object_id [String, nil] object ID for instance methods
      # @param arguments [Hash] method arguments
      # @return [Hash] method result
      def call_method(agent, class_name:, method_name:, object_id: nil, arguments: nil, **_kwargs)
        klass = Parse::Model.find_class(class_name)
        raise "Class not found: #{class_name}" unless klass

        method_sym = method_name.to_sym

        # Check if method is agent-allowed
        unless klass.respond_to?(:agent_method_allowed?) && klass.agent_method_allowed?(method_sym)
          raise "Method '#{method_name}' is not agent-allowed on #{class_name}. " \
                "Only methods marked with agent_method, agent_readonly, agent_write, or agent_admin can be called."
        end

        # Check permission level
        unless klass.agent_can_call?(method_sym, agent.permissions)
          method_info = klass.agent_method_info(method_sym)
          required = method_info[:permission] || :readonly
          raise "Permission denied: '#{method_name}' requires #{required} permissions. " \
                "Current level: #{agent.permissions}"
        end

        method_info = klass.agent_method_info(method_sym)
        args = arguments || {}
        args = args.transform_keys(&:to_sym) if args.is_a?(Hash)

        # Execute with timeout - user methods could be slow
        with_timeout(:call_method) do
          result = if method_info[:type] == :instance
              raise "object_id required for instance method '#{method_name}'" unless object_id
              obj = klass.find(object_id)
              raise "Object not found: #{class_name}##{object_id}" unless obj
              call_with_args(obj, method_sym, args)
            else
              call_with_args(klass, method_sym, args)
            end

          {
            class_name: class_name,
            method: method_name,
            object_id: object_id,
            result: serialize_result(result),
          }
        end
      end

      private

      # Execute a block with a timeout
      # @param tool_name [Symbol] the tool being executed (for error messages)
      # @yield the block to execute with timeout
      # @raise [Agent::ToolTimeoutError] if timeout is exceeded
      def with_timeout(tool_name)
        timeout = TOOL_TIMEOUTS[tool_name] || DEFAULT_TIMEOUT
        Timeout.timeout(timeout) { yield }
      rescue Timeout::Error
        raise Agent::ToolTimeoutError.new(tool_name, timeout)
      end

      # Call a method with arguments, handling both positional and keyword args.
      # Validates that the method is not on the blocked list to prevent
      # code execution via user-controlled method names.
      # @raise [ArgumentError] if the method is blocked.
      def call_with_args(target, method_sym, args)
        validate_method_name!(method_sym)
        if args.empty?
          target.public_send(method_sym)
        else
          # Try keyword args first, fall back to no args if method doesn't accept them
          begin
            target.public_send(method_sym, **args)
          rescue ArgumentError
            # Method might not accept keyword args
            target.public_send(method_sym)
          end
        end
      end

      # Validates that a method name is not on the blocked list.
      # @param method_name [Symbol, String] the method name to validate.
      # @raise [ArgumentError] if the method is blocked.
      def validate_method_name!(method_name)
        if BLOCKED_METHODS.include?(method_name.to_s)
          raise ArgumentError, "Method '#{method_name}' is blocked for security reasons"
        end
      end

      # Serialize method results for JSON output
      def serialize_result(result)
        case result
        when Parse::Object
          ResultFormatter.format_object(result.parse_class, result.attributes)[:object]
        when Array
          result.map { |item| serialize_result(item) }
        when Hash
          result.transform_values { |v| serialize_result(v) }
        when NilClass, TrueClass, FalseClass, Numeric, String
          result
        else
          result.to_s
        end
      end
    end
  end
end
