# encoding: UTF-8
# frozen_string_literal: true

require "digest"

module Parse
  class Agent
    # Developer-facing introspection mixin. Mixed into {Parse::Agent} via
    # `include Describe` so `agent.describe`, `agent.describe_for(class_name)`,
    # and `agent.would_permit?(...)` are instance methods on every agent.
    #
    # SECURITY POSTURE — this is operator-side observability, NOT data exposed
    # to the LLM. The operator wrote every rule the helper echoes back; showing
    # them their own configuration is just transparency. The output is NOT
    # included in any tool response, MCP `tools/list`, or `parse.agent.tool_call`
    # notification payload by default. If a deployment chooses to surface the
    # output (e.g. via a debug HTTP endpoint), it should be auth-gated on the
    # same boundary that authenticates the operator console.
    #
    # The `session_token` value is NEVER returned verbatim. {#auth_descriptor}
    # emits a stable SHA256-truncated fingerprint so two `describe` calls on
    # the same session correlate, but the raw bearer token never leaves the
    # method. Master-key mode is identified by the `:master_key` symbol only.
    module Describe
      # Full introspection Hash for the agent. Lists every layer that gates
      # what the agent can see and do, plus per-class metadata for the
      # classes the agent explicitly references.
      #
      # @param pretty [Boolean] when true, returns a multi-line String
      #   formatted for `puts` debugging instead of the structured Hash.
      #   The String is generated from the same data the Hash exposes.
      # @return [Hash, String]
      def describe(pretty: false)
        data = describe_hash
        pretty ? describe_pretty(data) : data
      end

      # Per-class breakdown for a single Parse class. Includes the agent's
      # effective reach for the class (visible? class-filter permitted?
      # canonical filter? per-agent filter? tenant-scoped?) plus the
      # class-level metadata declared via `agent_fields` / `agent_methods` /
      # `agent_large_fields`. Useful when an agent has 30 visible classes
      # and a developer is debugging one specific refusal.
      #
      # @param class_name [String, Symbol, Class] the Parse class to look up
      # @return [Hash] per-class introspection envelope
      def describe_for(class_name)
        cn = if class_name.is_a?(Class) && class_name.respond_to?(:parse_class)
            class_name.parse_class
          else
            class_name.to_s
          end
        {
          class_name:              cn,
          accessible:              describe_class_accessibility(cn),
          agent_fields:            class_field_allowlist(cn),
          agent_canonical_filter:  Parse::Agent::MetadataRegistry.canonical_filter(cn),
          per_agent_filter:        respond_to?(:filter_for) ? filter_for(cn) : nil,
          tenant_scope:            class_tenant_scope(cn),
          large_fields:            class_large_fields(cn),
          agent_methods:           class_agent_method_names(cn),
        }
      end

      # Dispatch-gate simulator. Runs every accessibility check that the
      # tool dispatcher would run, without actually invoking the tool.
      # Lets a developer answer "why is this agent refusing this call?"
      # in one line, without parsing the audit payload or tracing through
      # the tool implementation.
      #
      # TRACK-AGENT-8: mirrors the REAL dispatch gates in
      # {Parse::Agent#execute} and {Parse::Agent::Tools.assert_class_accessible!}.
      # The simulator now checks:
      #
      #   * tool filter (`tools:` kwarg / `tool_filter_*` sets) and
      #     permission-tier membership
      #   * env-gate (`PARSE_AGENT_ALLOW_WRITE_TOOLS` /
      #     `PARSE_AGENT_ALLOW_RAW_CRUD` for write tools;
      #     `PARSE_AGENT_ALLOW_SCHEMA_OPS` /
      #     `PARSE_AGENT_ALLOW_RAW_SCHEMA` for schema tools)
      #   * `class_name` accessibility, including hidden-class +
      #     master-key-except, per-agent class allowlist, AND the
      #     CLP `op:` gate (forwarded when an `op:` is supplied)
      #   * `master_atlas?` opt-in gate for `atlas_faceted_search`
      #   * `method_filtered?` for `call_method` when a
      #     `method_name:` is supplied
      #
      # @param tool_name [Symbol] the tool being checked
      # @param class_name [String, Symbol, Class, nil] optional class scope
      #   for tools that take a `class_name:` argument
      # @param op [Symbol, nil] optional CLP op (`:find`, `:get`,
      #   `:count`, `:create`, `:update`, `:delete`, `:addField`) for
      #   class-level CLP checks. When omitted, only the
      #   class-visibility gate runs; CLP is not consulted.
      # @param method_name [Symbol, String, nil] optional `agent_method`
      #   target for `call_method` simulation
      # @return [Hash] `{allowed: Boolean, reason: Symbol?, denied_at: Symbol?}`
      #   `reason` and `denied_at` are populated only when `allowed: false`.
      def would_permit?(tool_name, class_name: nil, op: nil, method_name: nil, **_kwargs)
        tool_sym = tool_name.to_sym

        # Tool filter — present at the per-instance layer. Preserve
        # the historical `:tool_filtered` reason regardless of whether
        # the denial came from tier or instance filter, since the
        # describe consumer reads it as "this tool will be refused"
        # rather than as the dispatcher's split error_code.
        unless allowed_tools.include?(tool_sym)
          return { allowed: false, reason: :tool_filtered, denied_at: :allowed_tools }
        end

        # Env-gate for raw CRUD / schema-mutating tools. Mirrors the
        # gate in Parse::Agent#execute at line 1639-1662.
        if Parse::Agent::WRITE_GATED_TOOLS.include?(tool_sym) &&
           !(Parse::Agent.write_tools_enabled? && Parse::Agent.raw_crud_enabled?)
          return { allowed: false, reason: :write_env_gate_disabled,
                   denied_at: :write_env_gate }
        end
        if Parse::Agent::SCHEMA_GATED_TOOLS.include?(tool_sym) &&
           !(Parse::Agent.schema_ops_enabled? && Parse::Agent.raw_schema_enabled?)
          return { allowed: false, reason: :schema_env_gate_disabled,
                   denied_at: :schema_env_gate }
        end

        # atlas_faceted_search opt-in (master_atlas: true required —
        # see tools.rb:atlas_faceted_search). Mirrors the explicit
        # opt-in inside the tool body so the simulator doesn't
        # over-report :permitted for a session-bound agent.
        if tool_sym == :atlas_faceted_search &&
           !(respond_to?(:master_atlas?) && master_atlas?)
          return { allowed: false, reason: :master_atlas_required,
                   denied_at: :master_atlas_gate }
        end

        # Class access gate — when the tool takes a class_name argument.
        # Includes CLP `op:` check when the caller supplied one,
        # mirroring assert_class_accessible!'s signature.
        if class_name
          cn = class_name.is_a?(Class) && class_name.respond_to?(:parse_class) ?
                 class_name.parse_class : class_name.to_s
          begin
            Parse::Agent::Tools.assert_class_accessible!(cn, agent: self, op: op)
          rescue Parse::Agent::AccessDenied => e
            kind = e.respond_to?(:kind) && e.kind ? e.kind : :access_denied
            return { allowed: false, reason: kind, denied_at: :assert_class_accessible! }
          rescue Parse::Agent::ValidationError
            return { allowed: false, reason: :invalid_argument, denied_at: :assert_class_accessible! }
          end
        end

        # method_filtered? — mirror the call_method gate at tools.rb:3948.
        # Only fires when the caller supplied a method_name AND the
        # tool is call_method (the method-filter only narrows that tool).
        if tool_sym == :call_method && method_name && class_name
          cn = class_name.is_a?(Class) && class_name.respond_to?(:parse_class) ?
                 class_name.parse_class : class_name.to_s
          if respond_to?(:method_filtered?) &&
             method_filtered?(method_name.to_sym, class_name: cn)
            return { allowed: false, reason: :method_filtered,
                     denied_at: :method_filtered }
          end
        end

        { allowed: true }
      end

      private

      # The Hash form of describe. Extracted so both describe(:pretty true/false)
      # paths share the same data source.
      def describe_hash
        {
          agent_id:       agent_id,
          agent_depth:    agent_depth,
          permissions:    @permissions,
          auth:           auth_descriptor,
          tenant_id:      tenant_id,
          classes:        filter_descriptor(@class_filter_only, @class_filter_except),
          tools:          tools_descriptor,
          methods:        filter_descriptor(@method_filter_only, @method_filter_except, transform: ->(s) { s.to_s }),
          filters:        per_agent_filters_summary,
          hidden_classes: Parse::Agent::MetadataRegistry.hidden_class_names,
          per_class:      per_class_descriptor,
          strict_modes:   {
            tool_filter:  strict_tool_filter?,
            class_filter: strict_class_filter?,
          },
          correlation_id: @correlation_id,
          prompt:         { version: Parse::Agent::PROMPT_VERSION },
        }
      end

      # Auth-context descriptor. Mirrors the agent's #auth_context type
      # so an acl_user / acl_role agent is NOT mis-reported as
      # `:master_key` just because it has an empty session_token.
      # TRACK-AGENT-8: previously this method keyed solely on
      # `@session_token` emptiness, so a scoped (acl_user/acl_role)
      # agent's describe output erroneously claimed master-key
      # posture. Session-token mode emits an 8-character SHA256-
      # truncated fingerprint so two `describe` calls on the same
      # session correlate to the same value without leaking the raw
      # bearer token. Other scoped modes return their type symbol
      # plus an :identity surfaced from auth_context.
      def auth_descriptor
        ctx = auth_context
        case ctx[:type]
        when :session_token
          { mode: :session_token,
            fingerprint: Digest::SHA256.hexdigest(@session_token.to_s)[0, 8] }
        when :acl_user
          { mode: :acl_user, identity: ctx[:identity] }
        when :acl_role
          { mode: :acl_role, identity: ctx[:identity] }
        else
          { mode: :master_key }
        end
      end

      # Normalize an only/except filter pair into a `{only:, except:}` Hash.
      # `transform:` is applied to each element when emitting — used to coerce
      # the methods filter's mixed Symbol/String entries to a uniform shape.
      def filter_descriptor(only_set, except_set, transform: nil)
        emit = ->(s) {
          return nil unless s
          arr = s.to_a
          arr = arr.map(&transform) if transform
          arr.sort
        }
        { only: emit.call(only_set), except: emit.call(except_set) }
      end

      def tools_descriptor
        {
          only:      @tool_filter_only && @tool_filter_only.to_a.sort,
          except:    @tool_filter_except && @tool_filter_except.to_a.sort,
          effective: allowed_tools.sort,
        }
      end

      def per_agent_filters_summary
        return nil if @filters.nil?
        @filters.each_with_object({}) do |(key, constraint), h|
          h[key.to_s] = constraint.keys.map(&:to_s).sort
        end
      end

      # Per-class descriptor — emitted only for classes the agent explicitly
      # references (in `classes:`, in `filters:`, or via a tenant-scoped
      # class with a tenant_id binding). Keeps `describe` output bounded;
      # `describe_for(class_name)` is the unbounded lookup for any single
      # class.
      def per_class_descriptor
        names = Set.new
        names.merge(@class_filter_only.to_a)   if @class_filter_only
        names.merge(@class_filter_except.to_a) if @class_filter_except
        if @filters
          names.merge(@filters.keys.reject { |k| k == :default }.map(&:to_s))
        end
        return {} if names.empty?

        names.sort.each_with_object({}) do |cn, h|
          h[cn] = describe_for(cn).reject { |k, _| k == :class_name }
        end
      end

      # Resolve the agent's accessibility for a single class.
      # Returns one of `:permitted`, `:hidden`, `:class_filter_excluded`,
      # `:hidden_master_key_only`. The values mirror the `denial_kind`
      # discriminators emitted in the audit payload so a developer reading
      # `describe_for` and a SOC consumer reading audit logs see the same
      # vocabulary.
      #
      # TRACK-AGENT-3 / TRACK-AGENT-8 (Bug 1): the master-key exception
      # gate keys on `auth_context[:using_master_key] == true`, NOT on
      # `@session_token` emptiness. An `acl_user` / `acl_role` agent
      # ALSO has an empty session_token but is NOT a master-key agent,
      # so the prior `@session_token.to_s.empty?` heuristic
      # over-reported `:permitted` for scoped agents against an
      # `agent_hidden(except: :master_key)` class — diverging from the
      # real gate at `tools.rb:1063`.
      def describe_class_accessibility(class_name)
        if Parse::Agent::MetadataRegistry.hidden?(class_name)
          except = Parse::Agent::MetadataRegistry.respond_to?(:hidden_exception_for) ?
                     Parse::Agent::MetadataRegistry.hidden_exception_for(class_name) : nil
          if except == :master_key && auth_context[:using_master_key] == true
            # Hidden from session-bound / acl_user / acl_role agents but
            # reachable by this master-key agent.
          else
            return :hidden
          end
        end
        if respond_to?(:class_filter_permits?) && !class_filter_permits?(class_name)
          return :class_filter_excluded
        end
        :permitted
      end

      # Per-class agent_fields allowlist, or nil when none declared. Returns
      # the wire-format field name Array so the output reads identically to
      # the schema-enriched `get_schema` echo.
      def class_field_allowlist(class_name)
        list = Parse::Agent::MetadataRegistry.field_allowlist(class_name)
        list && list.any? ? list.dup : nil
      end

      # Tenant-scope rule for the class plus the agent's tenant_id binding.
      # Returns `{field:, value:}` when both are set, nil otherwise. This is
      # the actual scope that would apply on a query against this class.
      def class_tenant_scope(class_name)
        return nil if tenant_id.nil?
        rule = Parse::Agent::MetadataRegistry.respond_to?(:tenant_scope_rule) ?
                 Parse::Agent::MetadataRegistry.tenant_scope_rule(class_name) : nil
        return nil unless rule
        { field: rule[:field], value: tenant_id }
      end

      # @agent_large_fields declared at the class level, surfaced via
      # `get_schema`'s `large_field: true` flag. Returns nil when the class
      # has no Ruby model or no declaration.
      def class_large_fields(class_name)
        klass = begin
            Parse::Model.find_class(class_name)
          rescue StandardError
            nil
          end
        return nil unless klass.respond_to?(:agent_large_fields_set)
        list = klass.agent_large_fields_set
        list && list.any? ? list.to_a.sort : nil
      end

      # Names of `agent_method` declarations on the class, narrowed to the
      # tier the agent can actually call (so describe doesn't mislead by
      # listing :admin methods on a :readonly agent's report).
      def class_agent_method_names(class_name)
        klass = begin
            Parse::Model.find_class(class_name)
          rescue StandardError
            nil
          end
        return nil unless klass.respond_to?(:agent_methods)
        methods = klass.agent_methods
        return nil if methods.nil? || methods.empty?
        callable = methods.select { |_name, meta| agent_can_call_method?(meta) }
        callable.keys.map(&:to_s).sort
      end

      # Internal — whether the agent's permission tier permits an agent_method
      # whose declared permission tier is `meta[:permission]`. Falls open when
      # the meta hash is missing a permission key (matches the existing
      # `call_method` dispatch default).
      def agent_can_call_method?(meta)
        return true unless meta.is_a?(Hash)
        declared = meta[:permission] || meta["permission"]
        return true if declared.nil?
        PERMISSION_HIERARCHY[@permissions].to_i >= PERMISSION_HIERARCHY[declared.to_sym].to_i
      end

      # Render the Hash describe-output as a multi-line String for
      # `puts agent.describe(pretty: true)` debugging. Format is read-once,
      # not parseable — Hash + JSON is the structured surface.
      def describe_pretty(data)
        lines = []
        auth = data[:auth]
        auth_line = auth[:mode] == :session_token ?
                      "#{auth[:mode]} (fingerprint=#{auth[:fingerprint]})" :
                      auth[:mode].to_s
        lines << "Parse::Agent #{data[:agent_id]} (depth=#{data[:agent_depth]}, correlation=#{data[:correlation_id] || "—"})"
        lines << "  auth:        #{auth_line}"
        lines << "  permissions: #{data[:permissions]}"
        lines << "  tenant_id:   #{data[:tenant_id] || "—"}"

        if data[:classes][:only] || data[:classes][:except]
          lines << "  classes:"
          lines << "    only:    #{data[:classes][:only].inspect}"   if data[:classes][:only]
          lines << "    except:  #{data[:classes][:except].inspect}" if data[:classes][:except]
        else
          lines << "  classes:     (no filter — every visible class reachable)"
        end

        lines << "  tools:"
        lines << "    only:      #{data[:tools][:only].inspect}"      if data[:tools][:only]
        lines << "    except:    #{data[:tools][:except].inspect}"    if data[:tools][:except]
        lines << "    effective: #{data[:tools][:effective].inspect}"

        if data[:methods][:only] || data[:methods][:except]
          lines << "  methods:"
          lines << "    only:    #{data[:methods][:only].inspect}"   if data[:methods][:only]
          lines << "    except:  #{data[:methods][:except].inspect}" if data[:methods][:except]
        end

        if data[:filters]
          lines << "  filters:"
          data[:filters].each do |k, fields|
            lines << "    #{k}: [#{fields.join(", ")}]"
          end
        end

        if data[:hidden_classes].any?
          lines << "  hidden_classes: #{data[:hidden_classes].inspect}"
        end

        if data[:per_class].any?
          lines << "  per_class:"
          data[:per_class].each do |cn, info|
            lines << "    #{cn}:"
            lines << "      accessible: #{info[:accessible]}"
            [:agent_fields, :agent_canonical_filter, :per_agent_filter,
             :tenant_scope, :large_fields, :agent_methods].each do |k|
              v = info[k]
              next if v.nil?
              lines << "      #{k}: #{v.inspect}"
            end
          end
        end

        sm = data[:strict_modes]
        lines << "  strict_modes: tool_filter=#{sm[:tool_filter]} class_filter=#{sm[:class_filter]}"
        lines.join("\n")
      end
    end
  end
end
