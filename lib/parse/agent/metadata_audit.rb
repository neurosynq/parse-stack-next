# encoding: UTF-8
# frozen_string_literal: true

module Parse
  class Agent
    # Boot-time / on-demand audit of agent metadata declarations across
    # the application's Parse::Object subclasses. Surfaces the gaps that
    # silently degrade an LLM's experience of the schema: classes with no
    # `agent_description`, properties on the allowlist with no
    # `_description:`, and `agent_fields` entries that don't resolve to
    # known wire columns.
    #
    # Returns structured data so callers can wire it into a boot warning,
    # a CI gate, or a Rake task. `print_summary` is a convenience for
    # interactive use (rails console, scripts).
    #
    # @example Programmatic use
    #   audit = Parse::Agent.audit_metadata
    #   if audit[:missing_class_descriptions].any?
    #     warn "Classes without descriptions: #{audit[:missing_class_descriptions]}"
    #   end
    #
    # @example Interactive use
    #   Parse::Agent::MetadataAudit.print_summary
    module MetadataAudit
      extend self

      # System/system-adjacent fields that are always present on every
      # Parse class and don't benefit from `_description:`. Excluded from
      # the missing-field-descriptions report.
      ALWAYS_PRESENT_FIELDS = %i[
        object_id objectId
        created_at createdAt
        updated_at updatedAt
        acl ACL
      ].freeze

      # Run the audit and return structured findings.
      #
      # @return [Hash]
      #   * :classes_audited [Integer] — number of classes inspected
      #   * :visible_classes_declared [Boolean] — whether the app uses
      #     opt-in `agent_visible` mode
      #   * :missing_class_descriptions [Array<String>] — Parse class names
      #     with no `agent_description`
      #   * :missing_field_descriptions [Hash<String, Array<Symbol>>] —
      #     class name -> property symbols missing `_description:`. When
      #     a class declares `agent_fields`, only allowlisted properties
      #     are counted; otherwise all declared properties.
      #   * :unresolvable_allowlist_entries [Hash<String, Array<Symbol>>] —
      #     `agent_fields` entries that don't appear in the class's
      #     `field_map` (likely typos that 4.2.1's wire-name translation
      #     will silently miss).
      #   * :canonical_filter_summary [Hash<String, Hash>] — per-class
      #     declared canonical filters, surfaced so the auditor can see
      #     which classes apply silent row-level predicates by default.
      def audit
        classes = audit_target_classes

        result = {
          classes_audited: classes.size,
          visible_classes_declared: Parse::Agent::MetadataRegistry.has_visible_classes?,
          missing_class_descriptions: [],
          missing_field_descriptions: {},
          unresolvable_allowlist_entries: {},
          canonical_filter_summary: {},
        }

        classes.each do |klass|
          name = parse_class_name_for(klass)
          next if name.nil?

          # Skip classes flagged agent_hidden — they're intentionally
          # opaque to the agent surface, and we shouldn't pretend the
          # missing description on them is a gap.
          next if klass.respond_to?(:agent_hidden?) && klass.agent_hidden?

          # Skip Parse system classes (`_`-prefixed parse_class names:
          # `_User`, `_Role`, `_Session`, `_Installation`, `_Product`,
          # `_Audience`). These are framework-supplied by parse-stack and
          # don't benefit from userland-authored agent_description — the
          # SDK is responsible for documenting them, not the application.
          # Without this skip, every app that doesn't opt into
          # `agent_visible` mode sees the system classes flooding
          # `missing_class_descriptions`, which discourages adoption of
          # the audit tool. Apps that DO want to document their system
          # classes can still call `agent_description` on `Parse::User`
          # etc. — the skip only suppresses the "missing" reports, not
          # the legitimate ones.
          next if name.to_s.start_with?("_")

          if klass.respond_to?(:agent_description) && klass.agent_description.nil?
            result[:missing_class_descriptions] << name
          end

          missing_fields = missing_field_descriptions_for(klass)
          result[:missing_field_descriptions][name] = missing_fields if missing_fields.any?

          unresolvable = unresolvable_allowlist_entries_for(klass)
          result[:unresolvable_allowlist_entries][name] = unresolvable if unresolvable.any?

          if klass.respond_to?(:agent_canonical_filter_for_apply) &&
             (cf = klass.agent_canonical_filter_for_apply) &&
             cf.any?
            result[:canonical_filter_summary][name] = cf.dup
          end
        end

        result[:missing_class_descriptions].sort!
        result
      end

      # Print a human-readable summary to the given IO (defaults to $stdout).
      # The structured data from {#audit} is the source of truth; this is a
      # convenience for interactive sessions.
      #
      # @param io [IO] destination (default $stdout)
      # @return [Hash] the audit findings (same shape as {#audit})
      def print_summary(io: $stdout)
        data = audit

        io.puts "Parse::Agent metadata audit"
        io.puts "=" * 40
        io.puts "Classes audited: #{data[:classes_audited]} " \
                "(#{data[:visible_classes_declared] ? "agent_visible mode" : "all-subclasses fallback"})"
        io.puts

        missing_classes = data[:missing_class_descriptions]
        io.puts "Missing class descriptions (#{missing_classes.size}):"
        if missing_classes.empty?
          io.puts "  (none)"
        else
          missing_classes.each { |n| io.puts "  - #{n}" }
        end
        io.puts

        missing_fields = data[:missing_field_descriptions]
        total_missing_fields = missing_fields.values.sum(&:size)
        io.puts "Missing field descriptions (#{total_missing_fields} across #{missing_fields.size} classes):"
        if missing_fields.empty?
          io.puts "  (none)"
        else
          missing_fields.sort.each do |class_name, fields|
            io.puts "  #{class_name} (#{fields.size}):"
            io.puts "    #{fields.map(&:to_s).join(", ")}"
          end
        end
        io.puts

        unresolvable = data[:unresolvable_allowlist_entries]
        io.puts "Unresolvable allowlist entries:"
        if unresolvable.empty?
          io.puts "  (none)"
        else
          unresolvable.sort.each do |class_name, entries|
            io.puts "  #{class_name}: #{entries.map(&:to_s).join(", ")}"
          end
        end
        io.puts

        filters = data[:canonical_filter_summary]
        io.puts "Canonical filters declared (#{filters.size}):"
        if filters.empty?
          io.puts "  (none)"
        else
          filters.sort.each do |class_name, filter|
            io.puts "  #{class_name}: #{filter.inspect}"
          end
        end

        data
      end

      # ----------------------------------------------------------------
      # Internals
      # ----------------------------------------------------------------

      # Resolve the set of classes to audit.
      #
      # When the application has opted into `agent_visible` mode, that
      # registry IS the canonical list — the developer has explicitly said
      # "these are the agent-facing classes." Otherwise fall back to every
      # Parse::Object subclass currently loaded (back-compat mode).
      #
      # @return [Array<Class>]
      def audit_target_classes
        if Parse::Agent::MetadataRegistry.has_visible_classes?
          Parse::Agent::MetadataRegistry.visible_classes
        else
          # `Parse::Object.descendants` is the same iteration path used by
          # `Parse::Model.find_class` to resolve a Parse class name to a
          # Ruby class. Walks every loaded subclass without going through
          # the find_class cache (which raises NameError on miss and would
          # corrupt the audit's "what's declared" view).
          Parse::Object.descendants.select do |klass|
            klass.respond_to?(:parse_class) && klass.parse_class
          end
        end
      end

      # The Parse-side class name for a Ruby class, or nil when the class
      # isn't a normal Parse::Object subclass (defensive — every entry in
      # audit_target_classes should pass this).
      def parse_class_name_for(klass)
        return nil unless klass.respond_to?(:parse_class)
        klass.parse_class
      end

      # Build the list of property symbols on a class that have no
      # `_description:` declaration. When `agent_fields` is declared, the
      # check is scoped to the allowlist (those are the agent-visible
      # fields and the ones the LLM will see); otherwise it covers every
      # declared property on the class.
      #
      # Excludes ALWAYS_PRESENT_FIELDS (the four system columns) since
      # those don't benefit from per-property descriptions.
      def missing_field_descriptions_for(klass)
        return [] unless klass.respond_to?(:property_descriptions)
        return [] unless klass.respond_to?(:field_map)

        described = klass.property_descriptions.keys.map(&:to_sym).to_set
        declared_properties = klass.field_map.keys.map(&:to_sym)

        candidates =
          if klass.respond_to?(:agent_field_allowlist) && klass.agent_field_allowlist.any?
            klass.agent_field_allowlist.map(&:to_sym)
          else
            declared_properties
          end

        candidates - described.to_a - ALWAYS_PRESENT_FIELDS
      end

      # `agent_fields` entries that don't resolve to a known property on
      # the class. These would silently miss after the 4.2.1 wire-name
      # translation — the symbol would columnize to a column the schema
      # doesn't carry, and the filter would strip nothing.
      def unresolvable_allowlist_entries_for(klass)
        return [] unless klass.respond_to?(:agent_field_allowlist)
        allowlist = klass.agent_field_allowlist
        return [] if allowlist.empty?
        return [] unless klass.respond_to?(:field_map)

        known = klass.field_map.keys.map(&:to_sym).to_set
        allowlist.map(&:to_sym).reject { |sym| known.include?(sym) }
      end
    end

    class << self
      # Convenience class-method form of {Parse::Agent::MetadataAudit#audit}.
      # See {MetadataAudit} for the full contract.
      #
      # @return [Hash] structured audit findings
      def audit_metadata
        Parse::Agent::MetadataAudit.audit
      end
    end
  end
end
