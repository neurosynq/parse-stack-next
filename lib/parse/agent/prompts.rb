# encoding: UTF-8
# frozen_string_literal: true

require "thread"
require_relative "errors"

module Parse
  class Agent
    # Standalone prompt catalog and renderer for the MCP prompts layer.
    #
    # This module can be loaded independently of the WEBrick MCPServer.
    # All references to Parse::Agent::PARSE_CONVENTIONS and
    # Parse::Agent::RelationGraph are resolved at call-time (inside lambda
    # bodies), so the file remains loadable standalone as long as those
    # constants exist by the time render() is invoked.
    #
    # == Extension API
    #
    # Third-party apps may register custom prompts:
    #
    #   Parse::Agent::Prompts.register(
    #     name:        "my_prompt",
    #     description: "Does something useful",
    #     arguments:   [{ "name" => "id", "description" => "Object ID", "required" => true }],
    #     renderer:    ->(args) { "Do the thing with #{args['id']}" }
    #   )
    #
    # A renderer lambda may return either:
    #   - A String — used directly as the message text; description defaults to
    #     "Parse analytics prompt: <name>".
    #   - A Hash with :description and :text keys — both are used verbatim in the
    #     MCP response.
    #
    # Registering a name that matches a builtin replaces the builtin in responses.
    # Call reset_registry! to restore builtins-only state (useful in tests).
    #
    module Prompts
      # -----------------------------------------------------------------------
      # Validators (verbatim from Parse::Agent::MCPServer private methods)
      # -----------------------------------------------------------------------
      module Validators
        # Parse identifier shape (matches Parse class & field names).
        IDENTIFIER_RE = /\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/.freeze
        # Parse objectId shape — alphanumeric, typically 10-32 chars.
        OBJECT_ID_RE = /\A[A-Za-z0-9]{1,32}\z/.freeze

        # @raise [Parse::Agent::ValidationError] if value is nil/empty or doesn't match the identifier pattern.
        # @return [String] the validated value
        def self.validate_identifier!(value, name)
          raise Parse::Agent::ValidationError, "missing required argument: #{name}" if value.nil? || value.to_s.empty?
          s = value.to_s
          return s if s.match?(IDENTIFIER_RE)
          raise Parse::Agent::ValidationError, "#{name} must match #{IDENTIFIER_RE.source} (got: #{s.inspect})"
        end

        # @raise [Parse::Agent::ValidationError] if value is nil/empty or doesn't match alphanumeric objectId.
        # @return [String] the validated value
        def self.validate_object_id!(value, name)
          raise Parse::Agent::ValidationError, "missing required argument: #{name}" if value.nil? || value.to_s.empty?
          s = value.to_s
          return s if s.match?(OBJECT_ID_RE)
          raise Parse::Agent::ValidationError, "#{name} must be an alphanumeric objectId (got: #{s.inspect})"
        end

        # @raise [Parse::Agent::ValidationError] if required and value is nil/empty, or if value is not valid ISO8601.
        # @return [String, nil] the normalised ISO8601 string, or nil when not required and absent
        def self.validate_iso8601!(value, name, required: true)
          if value.nil? || value.to_s.empty?
            return nil unless required
            raise Parse::Agent::ValidationError, "missing required argument: #{name}"
          end
          require "time"
          Time.iso8601(value.to_s).utc.iso8601(3)
        rescue ArgumentError
          raise Parse::Agent::ValidationError, "#{name} must be a valid ISO8601 timestamp (got: #{value.inspect})"
        end
      end

      # -----------------------------------------------------------------------
      # Built-in prompt catalog (string keys so list/render work in pure Ruby).
      # -----------------------------------------------------------------------
      BUILTIN_PROMPTS = [
        {
          "name" => "parse_conventions",
          "description" => "Generic Parse platform conventions (objectId, createdAt, pointer/date shapes, _User, ACL). Fetch once and prepend to your system message.",
          "arguments" => [],
        },
        {
          "name" => "parse_relations",
          "description" => "Compact ASCII diagram of class relationships derived from belongs_to and has_many :through => :relation. Pass `classes` for a subset slice (both endpoints must be in the set).",
          "arguments" => [
            { "name" => "classes", "description" => "Optional comma-separated subset, e.g. \"_User,Post,Company\"", "required" => false },
          ],
        },
        {
          "name" => "explore_database",
          "description" => "Survey all Parse classes: list them, count each, and summarize what each appears to store",
          "arguments" => [],
        },
        {
          "name" => "class_overview",
          "description" => "Describe a class in detail: schema, total count, and a few sample objects",
          "arguments" => [
            { "name" => "class_name", "description" => "Parse class name", "required" => true },
          ],
        },
        {
          "name" => "count_by",
          "description" => "Count objects in a class grouped by a field (e.g. users by workspace, projects by status)",
          "arguments" => [
            { "name" => "class_name", "description" => "Parse class to count", "required" => true },
            { "name" => "group_by", "description" => "Field to group by", "required" => true },
          ],
        },
        {
          "name" => "recent_activity",
          "description" => "Show the most recently created objects in a class (answers \"when was the last X created\")",
          "arguments" => [
            { "name" => "class_name", "description" => "Parse class name", "required" => true },
            { "name" => "limit", "description" => "Number of objects to return (default 10)", "required" => false },
          ],
        },
        {
          "name" => "find_relationship",
          "description" => "Find objects in one class related to a given object in another (e.g. members of a workspace)",
          "arguments" => [
            { "name" => "parent_class", "description" => "Class of the parent object (e.g. Workspace)", "required" => true },
            { "name" => "parent_id", "description" => "objectId of the parent", "required" => true },
            { "name" => "child_class", "description" => "Class to query (e.g. _User)", "required" => true },
            { "name" => "pointer_field", "description" => "Field on child_class that points to parent (e.g. workspace)", "required" => true },
          ],
        },
        {
          "name" => "created_in_range",
          "description" => "Count and sample objects created within a date range",
          "arguments" => [
            { "name" => "class_name", "description" => "Parse class name", "required" => true },
            { "name" => "since", "description" => "ISO8601 lower bound (inclusive)", "required" => true },
            { "name" => "until", "description" => "ISO8601 upper bound (exclusive); omit for now", "required" => false },
          ],
        },
      ].freeze

      # -----------------------------------------------------------------------
      # Builtin renderers — each lambda takes the args Hash and returns a String.
      # References to Parse::Agent constants are resolved at call-time.
      # -----------------------------------------------------------------------
      BUILTIN_RENDERERS = {
        "parse_conventions" => ->(args) {
          Parse::Agent::PARSE_CONVENTIONS
        },

        "parse_relations" => ->(args) {
          subset = args["classes"].to_s.split(",").map(&:strip).reject(&:empty?)
          subset.each { |c| Validators.validate_identifier!(c, "classes entry") }
          subset = nil if subset.empty?
          edges = Parse::Agent::RelationGraph.build(classes: subset)
          diagram = Parse::Agent::RelationGraph.to_ascii(edges)
          slice_note = subset ? " (subset: #{subset.join(", ")})" : ""
          empty_subset_hint = (subset && edges.empty?) ?
            " No edges matched the requested subset — check the class names for casing and spelling (e.g. `_User`, not `_user`)." : ""
          "Class relationships in this Parse database#{slice_note}.#{empty_subset_hint} " \
          "Owning-field names are camelCase exactly as stored in Parse. " \
          "Read each line as: <one side> ─<cardinality>→ <many side> (owning field). " \
          "Use the owning field name with `query_class where:` to filter by that pointer, or with `include:` to expand it.\n\n#{diagram}"
        },

        "explore_database" => ->(args) {
          "Survey the Parse database. Call get_all_schemas to list every class, then call count_objects on each to get totals. " \
          "Skip `_`-prefixed system classes other than `_User` and `_Role` (they may be empty, huge, or return errors). " \
          "Group remaining classes by likely purpose (users/auth, content, app-specific) and summarize what the database is for."
        },

        "class_overview" => ->(args) {
          cn = Validators.validate_identifier!(args["class_name"], "class_name")
          "Describe the #{cn} class. Call get_schema for #{cn}, count_objects to get the total, and get_sample_objects (limit: 3). Summarize fields, what the class represents, and notable values in the samples."
        },

        "count_by" => ->(args) {
          cn = Validators.validate_identifier!(args["class_name"], "class_name")
          gb = Validators.validate_identifier!(args["group_by"], "group_by")
          pipeline = [
            { "$group" => { "_id" => "$#{gb}", "count" => { "$sum" => 1 } } },
            { "$sort" => { "count" => -1 } },
            { "$limit" => 25 },
          ]
          "Count #{cn} objects grouped by #{gb}. Use aggregate with class_name=\"#{cn}\" and pipeline #{pipeline.to_json}. " \
          "If #{gb} is a pointer field, Parse returns each `_id` as the literal string \"ClassName$objectId\" (e.g. \"Workspace$abc123\") — strip the \"ClassName$\" prefix to recover the objectId, then optionally call get_object on a few to label them. " \
          "Report the top groups, call out any null/missing values, and give the total."
        },

        "recent_activity" => ->(args) {
          cn = Validators.validate_identifier!(args["class_name"], "class_name")
          limit = (args["limit"] || 10).to_i
          limit = 10 if limit <= 0
          limit = 100 if limit > 100
          "Show the #{limit} most recently created #{cn} objects. Use query_class with class_name=\"#{cn}\", order=\"-createdAt\", limit=#{limit}. Report the createdAt of the latest one prominently and highlight notable fields."
        },

        "find_relationship" => ->(args) {
          pc  = Validators.validate_identifier!(args["parent_class"],  "parent_class")
          pid = Validators.validate_object_id!(args["parent_id"],      "parent_id")
          cc  = Validators.validate_identifier!(args["child_class"],   "child_class")
          pf  = Validators.validate_identifier!(args["pointer_field"], "pointer_field")
          where = { pf => { "__type" => "Pointer", "className" => pc, "objectId" => pid } }
          "Find #{cc} objects whose #{pf} field points to #{pc} #{pid}. " \
          "First call count_objects with class_name=\"#{cc}\" and where=#{where.to_json}. " \
          "Then call query_class with the same constraint, limit 20, to show a sample. " \
          "Note: #{pf} must match the field name as stored (camelCase as defined in the schema). Report the count first."
        },

        "created_in_range" => ->(args) {
          cn    = Validators.validate_identifier!(args["class_name"], "class_name")
          since = Validators.validate_iso8601!(args["since"], "since")
          upper = Validators.validate_iso8601!(args["until"], "until", required: false)
          date_constraint = { "$gte" => { "__type" => "Date", "iso" => since } }
          date_constraint["$lt"] = { "__type" => "Date", "iso" => upper } if upper
          where = { "createdAt" => date_constraint }
          "Count #{cn} objects created since #{since}#{upper ? " and before #{upper}" : ""}. " \
          "Use count_objects with class_name=\"#{cn}\" and where=#{where.to_json}. " \
          "Then call query_class with the same where, order=\"-createdAt\", limit=10 for a sample. Report the count and the date range of the sample."
        },
      }.freeze

      # Thread-safety for the mutable registry.
      REGISTRY_MUTEX = Mutex.new
      private_constant :REGISTRY_MUTEX

      # Mutable registry of custom prompts: name => { entry:, renderer: }
      @registry = {}

      # Subscribers notified when the registry changes (register or
      # reset_registry!). Each entry is a callable invoked with no
      # arguments. Used by Parse::Agent::MCPRackApp::SSEBody to push
      # `notifications/prompts/list_changed` MCP events onto its SSE
      # wire. Iterated under a snapshot copy outside the mutex so a
      # misbehaving subscriber cannot block subsequent register calls.
      @subscribers = []

      class << self
        # Returns the full list of prompt definitions for the MCP prompts/list
        # response. Registered prompts override builtins with the same name.
        #
        # @return [Array<Hash>] array of prompt definition hashes with string keys.
        def list
          merged = {}
          BUILTIN_PROMPTS.each { |p| merged[p["name"]] = p }
          REGISTRY_MUTEX.synchronize do
            @registry.each { |name, entry| merged[name] = entry[:prompt] }
          end
          merged.values
        end

        # Renders a prompt by name and returns the MCP prompts/get response shape.
        #
        # @param name [String] prompt name
        # @param args [Hash<String,String>] user-supplied arguments
        # @return [Hash] { "description" => String, "messages" => Array }
        # @raise [Parse::Agent::ValidationError] if name is unknown or args fail validation
        def render(name, args = {})
          renderer = nil
          REGISTRY_MUTEX.synchronize { renderer = @registry[name]&.fetch(:renderer, nil) }
          renderer ||= BUILTIN_RENDERERS[name]

          raise Parse::Agent::ValidationError, "Unknown prompt: #{name}" if renderer.nil?

          result = renderer.call(args)

          if result.is_a?(Hash)
            description = (result[:description] || result["description"]).to_s
            text        = (result[:text] || result["text"]).to_s
          else
            description = "Parse analytics prompt: #{name}"
            text        = result.to_s
          end

          {
            "description" => description,
            "messages" => [
              {
                "role"    => "user",
                "content" => { "type" => "text", "text" => text },
              },
            ],
          }
        end

        # Register a custom prompt. Thread-safe. Idempotent on same name (replaces).
        #
        # @param name [String] unique prompt name
        # @param description [String] human-readable description
        # @param arguments [Array<Hash>] argument definitions with string keys
        # @param renderer [Proc] lambda accepting an args Hash; returns String or
        #   Hash with :description and :text keys
        def register(name:, description:, arguments: [], renderer:)
          prompt = {
            "name"        => name.to_s,
            "description" => description.to_s,
            "arguments"   => arguments,
          }
          REGISTRY_MUTEX.synchronize do
            @registry[name.to_s] = { prompt: prompt, renderer: renderer }
          end
          notify_subscribers
          nil
        end

        # Clears the custom registry, restoring builtins-only state.
        # Intended for use in test suites.
        def reset_registry!
          REGISTRY_MUTEX.synchronize { @registry.clear }
          notify_subscribers
          nil
        end

        # Subscribe to registry-changed events. The block is invoked
        # with no arguments after every {register} or {reset_registry!}
        # call. Returns a Proc that, when called, deregisters the
        # subscriber. Used by Parse::Agent::MCPRackApp::SSEBody to drive
        # MCP `notifications/prompts/list_changed` broadcasts.
        #
        # @yield no arguments
        # @return [Proc] call with no arguments to deregister.
        def subscribe(&block)
          raise ArgumentError, "block required" unless block

          REGISTRY_MUTEX.synchronize { @subscribers << block }
          -> { REGISTRY_MUTEX.synchronize { @subscribers.delete(block) } }
        end

        # Remove all subscribers. Intended for test suites.
        def reset_subscribers!
          REGISTRY_MUTEX.synchronize { @subscribers.clear }
          nil
        end

        # @api private
        def notify_subscribers
          snapshot = REGISTRY_MUTEX.synchronize { @subscribers.dup }
          snapshot.each do |callback|
            begin
              callback.call
            rescue StandardError => e
              warn "[Parse::Agent::Prompts] subscriber raised: #{e.class}: #{e.message}"
            end
          end
        end
      end
    end
  end
end
