# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module Core
    # Operator-facing introspection mixin. Extended onto Parse::Object so
    # `Model.describe` aggregates local model declarations, server schema,
    # CLP, and Atlas Search index state into a single Hash.
    #
    # SECURITY POSTURE — mirrors {Parse::Agent::Describe}. This is
    # operator-side observability, NOT data exposed to an LLM. Output is
    # never included in tool responses, MCP `tools/list`, or any
    # `parse.agent.*` notification payload. Surfacing it via a console or
    # debug endpoint requires auth-gating on the operator boundary.
    #
    # Network policy mirrors `agent.describe`: local-only by default. Opt
    # in to server fetches with `network: true`. Each section degrades
    # gracefully (`{available: false, reason: ...}`) instead of raising
    # when the underlying service is unreachable or unconfigured.
    module Describe
      LOCAL_SECTIONS   = %i[model acl].freeze
      NETWORK_SECTIONS = %i[schema clp atlas indexes].freeze
      ALL_SECTIONS     = (LOCAL_SECTIONS + NETWORK_SECTIONS).freeze

      # Core/built-in field keys we don't report under `:model[:fields]` —
      # they're inherited from Parse::Object (in both snake_case and
      # camelCase form) and add noise to every output.
      CORE_FIELD_KEYS = %i[
        id object_id created_at updated_at acl session_token
        objectId createdAt updatedAt ACL sessionToken
      ].freeze

      # Aggregate introspection for the class. Local-only by default; pass
      # `network: true` to include server schema, CLP, and Atlas Search.
      #
      # @param sections [Array<Symbol>] which sections to include. When
      #   empty, returns LOCAL_SECTIONS for `network: false` and
      #   ALL_SECTIONS for `network: true`. Valid: :model :acl :schema
      #   :clp :atlas.
      # @param pretty [Boolean] when true, returns a multi-line String for
      #   `puts` debugging instead of the Hash.
      # @param network [Boolean] permit per-section server/Mongo fetches.
      #   When false, network sections short-circuit to
      #   `{available: false, reason: :network_disabled}`.
      # @param client [Parse::Client, nil] optional client override for
      #   schema/clp fetches.
      # @param master [Boolean] forward an explicit master-key opt-in to
      #   admin-only sub-fetches (currently: `$indexStats` via
      #   {Parse::MongoDB.index_stats}, which requires `master: true`).
      #   When false (default), `usage:` counters degrade to `{}` and the
      #   `indexes` section reports `usage_available: false`. Pass
      #   `master: true` from an operator/audit context to populate real
      #   counters. The flag is NEVER auto-set by the SDK.
      # @note Valid sections: :model :acl :schema :clp :atlas :indexes.
      # @return [Hash, String]
      def describe(*sections, pretty: false, network: false, usage: false, master: false, client: nil)
        requested = sections.flatten.map(&:to_sym)
        active    = if requested.empty?
            network ? ALL_SECTIONS : LOCAL_SECTIONS
          else
            requested
          end

        data = { class_name: parse_class }
        active.each do |s|
          data[s] = describe_section(s, client: client, network: network, usage: usage, master: master)
        end
        pretty ? describe_pretty(data) : data
      end

      private

      def describe_section(section, client:, network:, usage: false, master: false)
        case section
        when :model  then describe_model_section
        when :acl    then describe_acl_section
        when :schema then network_section(network) { describe_schema_section(client) }
        when :clp    then network_section(network) { describe_clp_section(client) }
        when :atlas   then network_section(network) { describe_atlas_section }
        when :indexes then network_section(network) { describe_indexes_section(usage: usage, master: master) }
        else               { available: false, reason: :unknown_section }
        end
      end

      def network_section(network)
        return { available: false, reason: :network_disabled } unless network
        yield
      rescue StandardError => e
        { available: false, reason: :error, error: e.class.name, message: e.message }
      end

      def describe_model_section
        local_fields = fields.reject { |k, _| CORE_FIELD_KEYS.include?(k) }
        {
          parse_class:   parse_class,
          fields:        local_fields,
          field_count:   local_fields.size,
          references:    (respond_to?(:references) ? references.dup : {}),
          relations:     (respond_to?(:relations) ? relations.dup : {}),
          defaults:      (respond_to?(:defaults_list) ? defaults_list.dup : []),
          enums:         (respond_to?(:enums) ? enums.dup : {}),
          agent_fields:  (respond_to?(:agent_field_allowlist) && agent_field_allowlist.any? ?
                          agent_field_allowlist.map(&:to_s).sort : nil),
          agent_methods: agent_method_names_or_nil,
        }
      end

      def agent_method_names_or_nil
        return nil unless respond_to?(:agent_methods)
        methods = agent_methods
        return nil if methods.nil? || methods.empty?
        methods.keys.map(&:to_s).sort
      end

      def describe_acl_section
        defaults = respond_to?(:default_acls) ? default_acls : nil
        {
          default_acl:         defaults.respond_to?(:as_json) ? defaults.as_json : nil,
          default_acl_private: (respond_to?(:default_acl_private) ? !!default_acl_private : nil),
          acl_policy:          instance_variable_get(:@acl_policy_setting),
        }
      end

      def describe_schema_section(client)
        info = Parse::Schema.fetch(parse_class, client: client)
        return { available: false, reason: :class_missing_on_server } if info.nil?
        diff = Parse::Schema::SchemaDiff.new(self, info)
        {
          available:          true,
          in_sync:            diff.in_sync?,
          server_field_count: info.field_names.size,
          missing_on_server:  diff.missing_on_server,
          missing_locally:    diff.missing_locally,
          type_mismatches:    diff.type_mismatches,
        }
      end

      def describe_clp_section(client)
        info = Parse::Schema.fetch(parse_class, client: client)
        return { available: false, reason: :class_missing_on_server } if info.nil?
        { available: true, class_level_permissions: info.class_level_permissions }
      end

      def describe_atlas_section
        unless defined?(Parse::MongoDB) && Parse::MongoDB.respond_to?(:enabled?) && Parse::MongoDB.enabled?
          return { available: false, reason: :mongodb_not_enabled }
        end
        indexes = Parse::AtlasSearch::IndexManager.list_indexes(parse_class)
        {
          available: true,
          count:     indexes.size,
          indexes:   indexes.map { |i|
            { name:      i["name"],
              status:    i["status"],
              queryable: i["queryable"] }
          },
        }
      rescue => e
        msg = e.message.to_s
        reason = if defined?(Parse::AtlasSearch::NotAvailable) && e.is_a?(Parse::AtlasSearch::NotAvailable)
            :atlas_not_available
          else
            :error
          end
        { available: false, reason: reason, error: e.class.name, message: msg }
      end

      def describe_indexes_section(usage: false, master: false)
        unless defined?(Parse::MongoDB) && Parse::MongoDB.respond_to?(:enabled?) && Parse::MongoDB.enabled?
          return { available: false, reason: :mongodb_not_enabled }
        end
        raw = Parse::MongoDB.indexes(parse_class)
        # `Parse::MongoDB.index_stats` requires explicit `master: true`
        # because `$indexStats` discloses cluster metadata; without the
        # opt-in it rescues to `{}`, which surfaces as
        # `usage_available: false` below. Forward the caller's `master:`
        # so operator/audit callers can populate real counters.
        stats = if usage
            master ? Parse::MongoDB.index_stats(parse_class, master: true) : {}
          else
            {}
          end
        normalized = raw.map { |idx| normalize_index_entry(idx, stats: stats) }
        result = {
          available: true,
          count:     normalized.size,
          indexes:   normalized,
        }
        if usage
          # Empty stats Hash means the role lacks clusterMonitor / Atlas
          # restricts $indexStats; surface that so the operator can act
          # on it rather than reading absent counters as "zero traffic".
          result[:usage_available] = !stats.empty?
        end

        if respond_to?(:mongo_index_declarations) && mongo_index_declarations.any?
          # Migrator surfaces declared/drift only when the class opted
          # into the DSL — keeps the describe output clean for classes
          # that have not adopted `mongo_index`. Plan is a Hash keyed by
          # collection — surface the parent's parse_class plan as
          # `declared/drift/capacity` for the simple single-collection
          # case, and add a `relations:` sub-key listing per-collection
          # plans for any `_Join:*` collections from
          # `mongo_relation_index`.
          plans = Parse::Schema::IndexMigrator.new(self).plan
          base  = parse_class
          parent_plan = plans[base]
          if parent_plan
            result[:declared]      = parent_plan[:declared].map { |d| describe_decl(d) }
            result[:drift]         = describe_drift(parent_plan)
            result[:parse_managed] = parent_plan[:parse_managed]
            result[:capacity]      = describe_capacity(parent_plan)
          end
          join_plans = plans.reject { |k, _| k == base }
          unless join_plans.empty?
            result[:relations] = join_plans.each_with_object({}) do |(coll, p), h|
              h[coll] = {
                declared:      p[:declared].map { |d| describe_decl(d) },
                drift:         describe_drift(p),
                parse_managed: p[:parse_managed],
                capacity:      describe_capacity(p),
              }
            end
          end
        end

        result
      end

      def describe_decl(decl)
        { keys: decl[:keys], options: decl[:options], collection: decl[:collection] }
      end

      def describe_drift(plan)
        {
          to_create: plan[:to_create].map { |d| describe_decl(d) },
          in_sync:   plan[:in_sync].map   { |d| describe_decl(d) },
          orphans:   plan[:orphans],
          conflicts: plan[:conflicts],
        }
      end

      def describe_capacity(plan)
        {
          used:      plan[:capacity_used],
          after:     plan[:capacity_after],
          remaining: plan[:capacity_remaining],
          ok:        plan[:capacity_ok],
        }
      end

      # Pull out the operator-relevant fields and coerce BSON values into
      # JSON-safe primitives so the hash can be `JSON.dump`'d without
      # surprises. The driver returns BSON::ObjectId / BSON::Regexp::Raw
      # inside `partialFilterExpression` for some index shapes.
      #
      # When `stats:` is supplied (from `$indexStats`), merges in the
      # `usage:` sub-hash with `ops` and `since` counters for the index.
      def normalize_index_entry(idx, stats: {})
        name = idx["name"] || idx[:name]
        entry = {
          name:           name,
          implicit_id:    name == "_id_",
          key:            coerce_bson(idx["key"] || idx[:key] || {}),
          unique:         idx["unique"] == true,
          sparse:         idx["sparse"] == true,
          partial_filter: coerce_bson(idx["partialFilterExpression"] || idx[:partialFilterExpression]),
          expire_after_seconds: idx["expireAfterSeconds"] || idx[:expireAfterSeconds],
        }
        if (stat = stats[name])
          entry[:usage] = { ops: stat[:ops], since: stat[:since] }
        end
        entry
      end

      def coerce_bson(value)
        case value
        when Hash
          value.each_with_object({}) { |(k, v), h| h[k.to_s] = coerce_bson(v) }
        when Array
          value.map { |v| coerce_bson(v) }
        when Symbol, String, Numeric, TrueClass, FalseClass, NilClass
          value
        else
          value.to_s
        end
      end

      def describe_pretty(data)
        lines = ["#{data[:class_name]} describe:"]

        if (m = data[:model])
          lines << "  fields:     #{m[:field_count]}"
          lines << "  references: #{m[:references].inspect}" if m[:references].any?
          lines << "  relations:  #{m[:relations].inspect}"  if m[:relations].any?
          lines << "  defaults:   #{m[:defaults].inspect}"   if m[:defaults].any?
          lines << "  enums:      #{m[:enums].keys.inspect}" if m[:enums].any?
          lines << "  agent_fields:  #{m[:agent_fields].inspect}"  if m[:agent_fields]
          lines << "  agent_methods: #{m[:agent_methods].inspect}" if m[:agent_methods]
        end

        if (a = data[:acl])
          lines << "  default_acl: #{a[:default_acl].inspect}"
          lines << "  acl_policy:  #{a[:acl_policy].inspect}" if a[:acl_policy]
        end

        if (s = data[:schema])
          if s[:available]
            label = s[:in_sync] ? "in sync" : "drifted"
            lines << "  schema: #{label} (server fields=#{s[:server_field_count]})"
            lines << "    missing_on_server: #{s[:missing_on_server].keys.inspect}" if s[:missing_on_server].any?
            lines << "    missing_locally:   #{s[:missing_locally].keys.inspect}"   if s[:missing_locally].any?
            lines << "    type_mismatches:   #{s[:type_mismatches].keys.inspect}"   if s[:type_mismatches].any?
          else
            lines << "  schema: unavailable (#{s[:reason]})"
          end
        end

        if (c = data[:clp])
          if c[:available]
            lines << "  clp: #{c[:class_level_permissions].keys.inspect}"
          else
            lines << "  clp: unavailable (#{c[:reason]})"
          end
        end

        if (x = data[:atlas])
          if x[:available]
            lines << "  atlas_search: #{x[:count]} index(es)"
            x[:indexes].each { |i| lines << "    - #{i[:name]} (#{i[:status]}, queryable=#{i[:queryable]})" }
          else
            lines << "  atlas_search: unavailable (#{x[:reason]})"
          end
        end

        if (ix = data[:indexes])
          if ix[:available]
            lines << "  indexes: #{ix[:count]}"
            ix[:indexes].each do |i|
              flags = []
              flags << "unique" if i[:unique]
              flags << "sparse" if i[:sparse]
              flags << "ttl=#{i[:expire_after_seconds]}" if i[:expire_after_seconds]
              flags << "_id" if i[:implicit_id]
              flags << "ops=#{i[:usage][:ops]}" if i[:usage]
              suffix = flags.any? ? " [#{flags.join(", ")}]" : ""
              lines << "    - #{i[:name]} #{i[:key].inspect}#{suffix}"
            end
            if ix.key?(:usage_available)
              lines << "    usage: #{ix[:usage_available] ? "available" : "unavailable (role lacks clusterMonitor)"}"
            end
            if (drift = ix[:drift])
              lines << "    declared:    #{ix[:declared].size}"
              lines << "    to_create:   #{drift[:to_create].size}"   if drift[:to_create].any?
              lines << "    in_sync:     #{drift[:in_sync].size}"     if drift[:in_sync].any?
              lines << "    orphans:     #{drift[:orphans].inspect}"  if drift[:orphans].any?
              lines << "    conflicts:   #{drift[:conflicts].size}"   if drift[:conflicts].any?
            end
            if (cap = ix[:capacity])
              lines << "    capacity:    #{cap[:used]}/#{Parse::Core::Indexing::MAX_INDEXES_PER_COLLECTION} (#{cap[:remaining]} remaining)"
            end
            if (relations = ix[:relations])
              lines << "  relation_indexes:"
              relations.each do |coll, info|
                lines << "    #{coll}"
                lines << "      declared:  #{info[:declared].size}"
                d = info[:drift]
                lines << "      to_create: #{d[:to_create].size}" if d[:to_create].any?
                lines << "      in_sync:   #{d[:in_sync].size}"   if d[:in_sync].any?
                lines << "      orphans:   #{d[:orphans].inspect}" if d[:orphans].any?
              end
            end
          else
            lines << "  indexes: unavailable (#{ix[:reason]})"
          end
        end

        lines.join("\n")
      end
    end
  end
end
