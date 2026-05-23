# encoding: UTF-8
# frozen_string_literal: true

require "set"

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

      # Thread-safe storage for hidden classes — opt-in PII / sensitive
      # classes that are denied to every agent tool surface.
      @hidden_classes = []
      @hidden_mutex = Mutex.new

      # Per-class exception scopes for `agent_hidden(except: ...)`. Maps a class
      # object to the scope it permits (currently only :master_key). Absence
      # from this hash means the class is unconditionally hidden to every
      # agent regardless of auth context. Guarded by `@hidden_mutex` (no
      # separate mutex — every read/write happens alongside a hidden-set
      # access, so reusing the lock avoids the lock-order coupling of two).
      @hidden_exceptions = {}

      # Thread-safe storage for per-class tenant scope rules.
      # Maps parse_class_name => { field: Symbol, from: Proc }
      @tenant_scope_rules = {}
      @tenant_scope_mutex = Mutex.new

      # Thread-safe storage for per-class tenant scope bypass procs.
      # Maps parse_class_name => Proc
      @tenant_scope_bypasses = {}
      @tenant_scope_bypass_mutex = Mutex.new

      # Register a class as visible to agents.
      # @param klass [Class] the model class
      def register_visible_class(klass)
        @visible_mutex.synchronize do
          @visible_classes << klass unless @visible_classes.include?(klass)
        end
      end

      # Register a class as hidden from agent tools (opt-in PII denial).
      # @param klass [Class] the model class
      # @param except [Symbol, nil] when `:master_key`, the class is still
      #   reachable by master-key agents but refused for session-bound agents.
      #   When nil (default), the class is hidden from every agent regardless
      #   of auth context. Re-calling `register_hidden_class` with a different
      #   `except:` value updates the scope (last-write-wins) — this is what
      #   lets an application re-mark `Parse::Session` with the relaxed scope
      #   after the parse-stack default marked it with the strict one.
      def register_hidden_class(klass, except: nil)
        @hidden_mutex.synchronize do
          @hidden_classes << klass unless @hidden_classes.include?(klass)
          if except.nil?
            @hidden_exceptions.delete(klass)
          else
            @hidden_exceptions[klass] = except
          end
        end
      end

      # Reverse a prior `register_hidden_class` call. Used by `agent_unhidden`
      # to re-expose a class that was marked hidden by an upstream declaration
      # (typically a parse-stack built-in like `Parse::Product` or a base class
      # in an application's own model hierarchy). Removing the class from the
      # registry is what actually allows `query_class` / `aggregate` / schema
      # enumeration etc. to address it again — the per-class `@agent_hidden`
      # ivar alone is not consulted by the tool surface.
      # @param klass [Class] the model class
      def unregister_hidden_class(klass)
        @hidden_mutex.synchronize do
          @hidden_classes.delete(klass)
          @hidden_exceptions.delete(klass)
        end
      end

      # Look up the per-class hidden-exception scope (`:master_key` or nil) for
      # a Parse class name. Returns nil when the class is not hidden at all
      # OR when it is hidden with no exception. Caller must compare against
      # the agent's auth context to decide whether the exception applies.
      # @param class_name [String, Symbol]
      # @return [Symbol, nil]
      def hidden_exception_for(class_name)
        return nil if class_name.nil?
        target = class_name.to_s
        @hidden_mutex.synchronize do
          @hidden_classes.each do |klass|
            next unless hidden_name_variants_for(klass).include?(target)
            return @hidden_exceptions[klass]
          end
        end
        nil
      end

      # Class names (Parse class names) that are hidden from every agent tool.
      # @return [Array<String>]
      def hidden_class_names
        @hidden_mutex.synchronize { @hidden_classes.dup }.map do |klass|
          klass.respond_to?(:parse_class) ? klass.parse_class : klass.name
        end
      end

      # Check whether a class name is denied to agent tools.
      #
      # An LLM writing aggregations against Parse-on-Mongo will naturally
      # type system classes by their alias form (`"User"`, `"Role"`,
      # `"Installation"`, `"Session"`) even though the canonical
      # `parse_class` is the `_`-prefixed form (`"_User"`, etc.). Similarly,
      # a class declared with `parse_class "Foo"` lives in the registry as
      # `"Foo"` but a caller might pass the Ruby class name.
      #
      # {.hidden_name_variants_for} expands each registered hidden class to
      # every form a caller might submit; this predicate is a pure string
      # match against that expanded set. Closes the oracle where an LLM
      # could write `$lookup: { from: "User" }` and bypass an
      # `agent_hidden`-on-`Parse::User` because the registry only knew
      # `"_User"`.
      #
      # @param class_name [String, Symbol]
      # @return [Boolean]
      def hidden?(class_name)
        return false if class_name.nil?
        hidden_name_set.include?(class_name.to_s)
      end

      # All hidden-class name variants a caller might submit. Includes the
      # canonical `parse_class`, the un-prefixed alias when `parse_class`
      # starts with `_` (system-class form), and the Ruby class name when
      # it differs from `parse_class` (`parse_class "Foo"` override). The
      # `hidden_name_variants_for` helper MUST NOT take `@hidden_mutex` —
      # it's called from inside the synchronize block here, and recursive
      # locking would deadlock.
      # @return [Array<String>]
      def hidden_name_set
        @hidden_mutex.synchronize do
          @hidden_classes.flat_map { |klass| hidden_name_variants_for(klass) }.uniq
        end
      end

      # Compute the set of names a caller might use to reference `klass`.
      #
      # Variants emitted:
      #
      # - `parse_class` (canonical, always).
      # - `parse_class` stripped of a leading `_` (system-class alias form;
      #   e.g. `_User` -> `User`).
      # - Ruby class name when it differs from `parse_class`.
      #
      # **Known limitation — collision direction is safe but technically
      # over-broad.** If application code declares one class with
      # `parse_class "_Foo"` and *also* a separate class with
      # `parse_class "Foo"`, hiding the `_Foo` class implicitly causes
      # `hidden?("Foo")` to return true as well, refusing reads on the
      # un-prefixed sibling. The refusal direction is the safer one
      # (false positive on the gate, not a leak), and the collision is
      # contrived enough — `_`-prefixed parse_class names are reserved
      # in practice for Parse's own system classes — that we accept the
      # trade-off. Applications that genuinely need both can either rename
      # one, or call `agent_hidden` on both explicitly.
      #
      # @param klass [Class]
      # @return [Array<String>]
      def hidden_name_variants_for(klass)
        variants = []
        if klass.respond_to?(:parse_class) && klass.parse_class
          pc = klass.parse_class.to_s
          variants << pc
          variants << pc.sub(/\A_/, "") if pc.start_with?("_")
        end
        if klass.respond_to?(:name) && klass.name && !klass.name.include?("::") && !variants.include?(klass.name)
          # Skip names containing `::` -- those are Ruby constant paths
          # (e.g. `"Parse::User"`) that no LLM would write in a `$lookup`,
          # and including them only adds noise to `hidden_name_set`.
          variants << klass.name
        end
        variants
      end

      # Check whether a class name is accessible to agent tools.
      # Inverse of {#hidden?}. Use at tool-dispatch time to refuse access
      # before any query hits Parse Server.
      # @param class_name [String, Symbol]
      # @return [Boolean]
      def accessible?(class_name)
        !hidden?(class_name)
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

      # Fields that always pass through the agent_fields allowlist filter.
      # These carry semantic meaning the LLM needs even when not explicitly
      # listed as analytics-relevant.
      ALWAYS_KEEP_FIELDS = %w[objectId createdAt updatedAt].freeze

      # Per-field metadata keys that bloat the agent schema response without
      # helping analytics queries. Dropped before the schema reaches the LLM.
      NOISY_FIELD_METADATA = %w[indexed].freeze

      # Enrich a server schema with local model metadata.
      #
      # @param class_name [String] the Parse class name
      # @param server_schema [Hash] the schema from Parse Server
      # @param agent_permission [Symbol] the agent's permission level for method filtering
      # @param edges [Array<Hash>, nil] pre-built relation edges from
      #   {RelationGraph.build}. When omitted, edges are built on demand for
      #   this single class; pass a pre-built array when enriching many
      #   schemas in a row to avoid the N+1 traversal.
      # @return [Hash] the enriched schema
      def enriched_schema(class_name, server_schema, agent_permission: :readonly, edges: nil)
        klass = find_model_class(class_name)
        return server_schema unless klass&.respond_to?(:has_agent_metadata?) && klass.has_agent_metadata?

        schema = deep_dup(server_schema)

        # Add class description
        if klass.agent_description
          schema["description"] = klass.agent_description
        end

        # Add class-level analytics usage hint (distinct from description)
        if klass.respond_to?(:agent_usage) && klass.agent_usage
          schema["usage"] = klass.agent_usage
        end

        # Enrich fields with property descriptions
        if schema["fields"] && klass.property_descriptions.any?
          schema["fields"] = enrich_fields(schema["fields"], klass)
        end

        # Filter fields to the declared allowlist (plus always-on system fields).
        # When no allowlist is declared, leave the field set alone.
        # Delegates to field_allowlist so allowlist symbols declared as Ruby
        # property names (snake_case) are normalized to the wire-format column
        # names (camelCase or explicit `field:` alias) before comparing against
        # Parse Server's schema keys. Without this normalization a model with
        # `agent_fields :device_type` filters against `"device_type"`, but the
        # server schema carries `"deviceType"` and the field is silently
        # stripped.
        if schema["fields"] && (allowed = field_allowlist(class_name))
          schema["fields"] = schema["fields"].select { |name, _| allowed.include?(name) }
        end

        # Strip noisy per-field metadata regardless of allowlist
        if schema["fields"]
          schema["fields"] = schema["fields"].transform_values do |config|
            next config unless config.is_a?(Hash)
            cleaned = config.reject { |k, _| NOISY_FIELD_METADATA.include?(k) }
            # Drop defaultValue if it's effectively empty (nil/empty string carry no signal)
            cleaned = cleaned.reject { |k, v| k == "defaultValue" && (v.nil? || v == "") }
            cleaned
          end
        end

        # Add agent-allowed methods (filtered by permission)
        available_methods = klass.agent_methods_for(agent_permission)
        if available_methods.any?
          schema["agent_methods"] = format_methods(available_methods)
        end

        # Surface the canonical "valid state" filter so an LLM that opts
        # out via `apply_canonical_filter: false` on a query can
        # reproduce the same predicate manually. The filter is applied
        # BY DEFAULT on `query_class`/`count_objects`/`aggregate`.
        canonical = klass.respond_to?(:agent_canonical_filter_for_apply) ?
          klass.agent_canonical_filter_for_apply : nil
        if canonical && canonical.any?
          schema["canonical_filter"] = canonical.dup
        end

        # Echo the wire-format `agent_fields` allowlist explicitly. The
        # registry already enforces the allowlist by stripping non-allowed
        # fields from `schema["fields"]`, but enforcement-by-omission left
        # an LLM guessing what it could write in `keys:` and led to
        # repeated refusals on storage-form column names (`_p_author`,
        # etc.). Listing the wire names alongside the trimmed fields hash
        # closes that gap. `ALWAYS_KEEP_FIELDS` (objectId/createdAt/
        # updatedAt) is filtered out — those are always available and
        # would only noise up the echo.
        allowed = field_allowlist(class_name)
        if allowed && (allowed - ALWAYS_KEEP_FIELDS).any?
          schema["agent_fields"] = (allowed - ALWAYS_KEEP_FIELDS)
        end

        # Echo the narrower join projection (wire-format) when declared.
        # Tells the LLM "when I'm included as a pointer on another class's
        # query, you'll see these fields and nothing else" so it can plan
        # the include path without a follow-up `get_schema`.
        join_proj = join_projection_fields(class_name)
        if join_proj && (join_proj[:project] - ALWAYS_KEEP_FIELDS).any?
          schema["agent_join_fields"] = (join_proj[:project] - ALWAYS_KEEP_FIELDS)
        end

        # Embed this class's relationship edges (incoming/outgoing) so the LLM
        # sees pointer/relation context alongside fields. Keeps each schema
        # response self-contained without the cost of the full graph.
        per_class = Parse::Agent::RelationGraph.edges_for(class_name, edges)
        if per_class[:outgoing].any? || per_class[:incoming].any?
          schema["relations"] = {
            "outgoing" => per_class[:outgoing].map { |e| edge_summary(e) },
            "incoming" => per_class[:incoming].map { |e| edge_summary(e) },
          }
        end

        schema
      end

      # Resolve the agent_fields allowlist for a Parse class name. Returns an
      # array of field-name strings including the always-keep system fields,
      # or nil when the model has no allowlist declared (callers should treat
      # nil as "no filtering — return everything").
      #
      # @param class_name [String] the Parse class name
      # @return [Array<String>, nil] allowlist or nil
      def field_allowlist(class_name)
        klass = find_model_class(class_name)
        return nil unless klass&.respond_to?(:agent_field_allowlist)
        allowlist = klass.agent_field_allowlist
        return nil if allowlist.empty?
        # Translate each allowlist entry to its wire-format column name.
        # Priority: the class's field_map (Ruby symbol -> wire symbol) so
        # explicit `field:` aliases (`property :external_id, field: "ExtId"`)
        # resolve to the actual column. Fallback: `String#columnize` so plain
        # snake_case Ruby names (`:device_type` -> `"deviceType"`) match
        # Parse Server's lowerCamelCase wire format. Without this translation
        # the allowlist filter was case-sensitive against snake_case strings
        # and silently stripped legitimate camelCase columns from schema
        # enrichment, `keys:` projection, and pipeline policy enforcement.
        fmap = klass.respond_to?(:field_map) ? klass.field_map : {}
        resolved = allowlist.map do |name|
          mapped = fmap[name.to_sym]
          # When field_map carries an explicit wire name (e.g. a `property
          # :external_id, field: :ExternalReferenceCode` alias), use it
          # verbatim — columnize would lowercase the first character and
          # break the alias. Without a mapping, columnize the Ruby symbol
          # to convert snake_case to lowerCamelCase wire format.
          mapped ? mapped.to_s : name.to_s.columnize
        end
        # Defense-in-depth: refuse to surface Parse Server internal columns
        # (`_hashed_password`, `_session_token`, `_rperm`/`_wperm`, etc.) on
        # the agent surface, regardless of whether a developer accidentally
        # mapped a `property :pw, field: :_hashed_password` and listed it in
        # `agent_fields`. The columnize fallback already strips the leading
        # underscore for snake_case entries; this drop targets the wire-name
        # path that bypasses columnize.
        resolved.reject! { |wire| Parse::PipelineSecurity::INTERNAL_FIELDS_DENYLIST.include?(wire) }
        resolved | ALWAYS_KEEP_FIELDS
      end

      # Resolve the wire-format projection set used when this class appears
      # as an included pointer on another class's query. Drives the
      # auto-projection that turns `keys: ["user"] + include: ["user"]`
      # into `keys: "user,user.firstName,user.email,..."` server-side.
      #
      # Resolution order (first match wins):
      #
      #   1. `agent_join_fields` → those entries (wire-format).
      #   2. `agent_fields` declared → `agent_fields - agent_large_fields`.
      #   3. Only `agent_large_fields` declared → all `field_map` properties
      #      minus the large set.
      #   4. None of the above → nil (no auto-projection; caller gets the
      #      full included record exactly as Parse Server returns it).
      #
      # The returned array always includes `ALWAYS_KEEP_FIELDS` (objectId /
      # createdAt / updatedAt). Internal Parse Server columns
      # (`_hashed_password`, `_session_token`, `_rperm`, etc.) are filtered
      # at the end as a defense-in-depth pass, identical to
      # {#field_allowlist}, so an accidental `property :pw, field:
      # :_hashed_password` cannot leak through the join surface.
      #
      # @param class_name [String] the joined Parse class name
      # @return [Hash, nil] {project: Array<String>, dropped: Array<String>,
      #   source: Symbol} or nil. `project` is the positive wire-format
      #   field list. `dropped` is the wire names this projection actively
      #   omits (used to populate the `truncated_include_fields` envelope).
      #   `source` is one of :join_fields, :allowlist_minus_large,
      #   :field_map_minus_large for diagnostics / testing.
      def join_projection_fields(class_name)
        klass = find_model_class(class_name)
        return nil unless klass
        fmap = klass.respond_to?(:field_map) ? klass.field_map : {}
        to_wire = ->(sym) {
          mapped = fmap[sym.to_sym]
          mapped ? mapped.to_s : sym.to_s.columnize
        }
        large_wire = if klass.respond_to?(:agent_large_field_list)
            klass.agent_large_field_list.map(&to_wire)
          else
            []
          end

        join_list = klass.respond_to?(:agent_join_field_list) ? klass.agent_join_field_list : []
        if join_list.any?
          project = join_list.map(&to_wire)
          source = :join_fields
          # dropped: large fields that are NOT in the join projection.
          # The caller asked us to project to a narrow set; report large
          # fields they didn't include so they can re-ask explicitly.
          dropped = large_wire - project
          return finalize_join_projection(project, dropped, source)
        end

        allow_list = klass.respond_to?(:agent_field_allowlist) ? klass.agent_field_allowlist : []
        if allow_list.any?
          allow_wire = allow_list.map(&to_wire)
          project = allow_wire - large_wire
          # If everything in the allowlist is also large, fall through
          # rather than projecting to an empty set (would surface a useless
          # `{}` user object).
          unless project.empty?
            dropped = large_wire & allow_wire
            return finalize_join_projection(project, dropped, :allowlist_minus_large)
          end
        end

        if large_wire.any?
          # Strip mode: no positive allowlist, but we know which fields are
          # heavy. Project to (declared properties - large fields). Limited
          # to fields the Ruby model knows about — server-side columns not
          # declared as `property` won't come back, but that's an honest
          # trade-off (we can only project what we can name).
          known_wire = fmap.values.map(&:to_s)
          project = known_wire - large_wire
          return nil if project.empty?
          dropped = large_wire & known_wire
          return finalize_join_projection(project, dropped, :field_map_minus_large)
        end

        nil
      end

      # @api private
      def finalize_join_projection(project, dropped, source)
        project = (project | ALWAYS_KEEP_FIELDS)
        project.reject! { |wire| Parse::PipelineSecurity::INTERNAL_FIELDS_DENYLIST.include?(wire) }
        dropped = dropped.reject { |wire| Parse::PipelineSecurity::INTERNAL_FIELDS_DENYLIST.include?(wire) }
        { project: project, dropped: dropped, source: source }
      end

      # Enrich multiple schemas at once. Builds the relation graph exactly
      # once and threads it through each per-schema enrichment so the
      # combined call is O(classes) rather than O(classes^2).
      #
      # @param server_schemas [Array<Hash>] schemas from Parse Server
      # @param agent_permission [Symbol] the agent's permission level
      # @return [Array<Hash>] enriched schemas
      def enriched_schemas(server_schemas, agent_permission: :readonly)
        edges = Parse::Agent::RelationGraph.build
        server_schemas.map do |schema|
          enriched_schema(schema["className"], schema, agent_permission: agent_permission, edges: edges)
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

      # Check whether COLLSCANs are explicitly permitted for the given class.
      # Returns true when the model declares `agent_allow_collscan true`, false
      # otherwise (including when no model class is registered).
      #
      # @param class_name [String] the Parse class name
      # @return [Boolean]
      def allow_collscan?(class_name)
        klass = find_model_class(class_name)
        return false unless klass&.respond_to?(:agent_allow_collscan?)
        klass.agent_allow_collscan?
      end

      # Look up the canonical "valid state" filter declared via
      # `agent_canonical_filter` on the model class. Returns nil when
      # no filter is declared.
      #
      # @param class_name [String] the Parse class name
      # @return [Hash, nil] a String-keyed where-style hash, or nil
      def canonical_filter(class_name)
        klass = find_model_class(class_name)
        return nil unless klass&.respond_to?(:agent_canonical_filter_for_apply)
        klass.agent_canonical_filter_for_apply
      end

      # ============================================================
      # Tenant Scope Registry
      # ============================================================

      # Register a tenant scope rule for a class.
      #
      # @param class_name [String] the Parse class name
      # @param field [Symbol] the field to scope on
      # @param from [Proc] callable receiving agent, returning the scope value
      def register_tenant_scope(class_name, field, from:)
        @tenant_scope_mutex.synchronize do
          @tenant_scope_rules[class_name.to_s] = { field: field.to_sym, from: from }
        end
      end

      # Register a bypass proc for a class's tenant scope.
      #
      # @param class_name [String] the Parse class name
      # @param bypass_proc [Proc] callable receiving agent, returning truthy to bypass
      def register_tenant_scope_bypass(class_name, bypass_proc)
        @tenant_scope_bypass_mutex.synchronize do
          @tenant_scope_bypasses[class_name.to_s] = bypass_proc
        end
      end

      # Return the tenant scope rule for a class name, or nil if none declared.
      #
      # @param class_name [String] the Parse class name
      # @return [Hash, nil] { field: Symbol, from: Proc } or nil
      def tenant_scope_rule(class_name)
        @tenant_scope_mutex.synchronize { @tenant_scope_rules[class_name.to_s] }
      end

      # Check whether the given agent should bypass the tenant scope for a class.
      # Returns false when no bypass is registered or when the bypass proc raises.
      #
      # @param class_name [String] the Parse class name
      # @param agent [Parse::Agent] the agent instance
      # @return [Boolean]
      def tenant_scope_bypassed?(class_name, agent)
        bypass = @tenant_scope_bypass_mutex.synchronize { @tenant_scope_bypasses[class_name.to_s] }
        return false unless bypass
        begin
          !!bypass.call(agent)
        rescue StandardError
          # A bypass proc that raises is treated as not-bypassed (fail closed).
          false
        end
      end

      # Resolve the effective tenant scope for a class and agent.
      #
      # Returns nil when:
      #   - No agent_tenant_scope is declared for this class (back-compat pass-through).
      #   - The bypass condition is satisfied (admin agents, etc.).
      #
      # Returns { field: Symbol, value: Object } when a scope should be enforced.
      #
      # Raises Parse::Agent::AccessDenied when:
      #   - A scope rule is declared and the bypass is not satisfied, but the
      #     agent's scope value (from: proc) returns nil — meaning the agent
      #     has no tenant binding and must not touch this class.
      #
      # @param class_name [String] the Parse class name
      # @param agent [Parse::Agent] the agent instance
      # @return [Hash, nil] { field: Symbol, value: Object } or nil
      # @raise [Parse::Agent::AccessDenied]
      def resolve_tenant_scope(class_name, agent)
        rule = tenant_scope_rule(class_name)
        return nil unless rule

        return nil if tenant_scope_bypassed?(class_name, agent)

        value = rule[:from].call(agent)
        if value.nil?
          raise Parse::Agent::AccessDenied.new(
            class_name,
            "Agent has no tenant binding for class '#{class_name}' which requires tenant scoping",
          )
        end

        { field: rule[:field], value: value }
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
        enums        = klass.respond_to?(:property_enum_descriptions) ?
                         klass.property_enum_descriptions : {}
        large_fields = klass.respond_to?(:agent_large_field_list) ? klass.agent_large_field_list : []
        large_set    = large_fields.map(&:to_sym).to_set

        # Reverse field_map (wire symbol -> Ruby symbol) so descriptions
        # and enums declared on properties with an explicit `field:`
        # alias resolve correctly. Example: `property :external_status,
        # :string, field: :ExtStatus, _description: "..."` stores the
        # description under `:external_status`, but the server returns
        # the column as `"ExtStatus"`. The 3-key sym/underscore/string
        # chain misses it (`"ExtStatus".underscore.to_sym == :ext_status
        # != :external_status`); the reverse lookup finds the Ruby
        # property symbol from the wire name and recovers. Same bug
        # class as the 4.2.1 fix on field_allowlist — the lookup must
        # consult field_map to honor explicit aliases.
        fmap_reverse = klass.respond_to?(:field_map) ? klass.field_map.invert : {}

        fields.transform_keys.with_object({}) do |name, result|
          config = fields[name]
          config = config.is_a?(Hash) ? deep_dup(config) : { "type" => config.to_s }

          # Look up description by the field_map reverse (property with
          # an explicit `field:` alias), then by symbol, then by camelCase.
          ruby_sym_from_wire = fmap_reverse[name.to_sym] || fmap_reverse[name.to_s.to_sym]
          desc = (ruby_sym_from_wire && descriptions[ruby_sym_from_wire]) ||
                 descriptions[name.to_sym] ||
                 descriptions[name.to_s.underscore.to_sym] ||
                 descriptions[name.to_s]

          config["description"] = desc if desc

          # Per-value enum descriptions. Same 4-key lookup as the
          # description path: reverse-mapped Ruby symbol (honors `field:`
          # aliases), declared property symbol, underscored wire name,
          # raw string. Emitted as a list of `{value:, description:}`
          # objects so the JSON shape round-trips cleanly through MCP
          # without depending on Hash ordering semantics in the consumer.
          enum_hash = (ruby_sym_from_wire && enums[ruby_sym_from_wire]) ||
                      enums[name.to_sym] ||
                      enums[name.to_s.underscore.to_sym] ||
                      enums[name.to_s]
          if enum_hash.is_a?(Hash) && enum_hash.any?
            config["allowed_values"] = enum_hash.map do |value, value_desc|
              { "value" => value.to_s, "description" => value_desc.to_s }
            end
          end

          # `agent_large_fields` annotation. Skip Pointer/Relation types —
          # the stored value is a small reference; only `include:`
          # resolution materializes the underlying payload, and that is a
          # query-time concern, not a schema-time hint.
          ftype = config["type"].to_s
          unless ftype == "Pointer" || ftype == "Relation"
            sym_name = name.to_s.underscore.to_sym
            if large_set.include?(sym_name) || large_set.include?(name.to_sym)
              config["large_field"] = true
            end
          end

          result[name] = config
        end
      end

      # Compact a relation edge for inline schema embedding. Drops the
      # `kind:` symbol (the `cardinality` already conveys belongs_to vs
      # relation: `1:N` vs `N:M`) to keep the schema response short.
      def edge_summary(edge)
        {
          "from" => edge[:from],
          "to" => edge[:to],
          "via" => edge[:via],
          "cardinality" => edge[:cardinality],
        }
      end

      # Format methods hash for schema output.
      #
      # Emits the full contract per declared `agent_method`: name, type
      # (class vs instance), permission tier, description, dry-run
      # support, the permitted_keys allowlist (when declared), and the
      # parameters JSON Schema (when declared). Lets MCP consumers of
      # `get_schema` discover which `call_method` invocations are
      # available on a class WITHOUT needing prior knowledge of method
      # names. Empty values are omitted via `.compact` so the wire
      # envelope stays tight on methods that declared only the minimum.
      #
      # @param methods [Hash<Symbol, Hash>] the methods to format
      # @return [Array<Hash>] formatted method list
      def format_methods(methods)
        methods.map do |name, info|
          # `permitted_keys` names the keys accepted by `call_method` for
          # this method. Disclosing it by default enumerates the write-field
          # authorization boundary. Gate it behind `Parse::Agent.agent_debug?`
          # (default false) so production `get_schema` responses do not
          # expose which fields are mutable. Enable in trusted internal
          # environments where the LLM needs the full method contract.
          keys = Parse::Agent.agent_debug? ? info[:permitted_keys]&.map(&:to_s) : nil
          {
            name:             name.to_s,
            type:             info[:type]&.to_s || "unknown",
            permission:       info[:permission]&.to_s || "readonly",
            description:      info[:description],
            supports_dry_run: info[:supports_dry_run] ? true : nil,
            permitted_keys:   keys,
            parameters:       info[:parameters],
          }.compact
        end
      end
    end
  end
end
