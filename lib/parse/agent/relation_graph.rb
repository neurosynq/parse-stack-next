# encoding: UTF-8
# frozen_string_literal: true

module Parse
  class Agent
    # RelationGraph derives the class-relationship graph from Parse Stack's
    # existing `belongs_to` and `has_many :through => :relation` declarations,
    # with no extra model DSL required. Each edge is a hash:
    #
    #   { from:, to:, via:, cardinality:, kind: }
    #
    # `from`/`to` are Parse class names; `via` is the owning side's field path
    # (`Post.author`); `cardinality` is `"1:N"` for pointer edges and `"N:M"`
    # for relation columns; `kind` is `:belongs_to` or `:relation`.
    #
    # Convention: pointer edges are emitted from the target ("the one") to the
    # source ("the many"), so `Post.author → _User` reads as
    # `_User ─1:N→ Post  (Post.author)` — natural English.
    #
    # @example Full graph
    #   Parse::Agent::RelationGraph.build
    #
    # @example Subset (both endpoints must be in the set)
    #   Parse::Agent::RelationGraph.build(classes: %w[_User Post])
    #
    # @example ASCII diagram for prompt text
    #   puts Parse::Agent::RelationGraph.to_ascii(
    #     Parse::Agent::RelationGraph.build
    #   )
    #
    module RelationGraph
      extend self

      # Conservative identifier shape used to sanitize edge components before
      # rendering them into LLM-facing text. Edges sourced from gem-internal
      # introspection should already match; the filter is defense in depth
      # against any future code path that lets remote input into class/field
      # naming (would otherwise be a prompt-injection channel).
      SAFE_IDENTIFIER = /\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/.freeze
      SAFE_VIA = %r{\A[A-Za-z_][A-Za-z0-9_]{0,127}\.[A-Za-z_][A-Za-z0-9_]{0,127}\z}.freeze

      # System classes that participate in normal analytics queries and should
      # remain visible by default. Other `_`-prefixed Parse internals are
      # filtered out so the graph stays aligned with the `explore_database`
      # prompt that already tells the LLM to skip them.
      ANALYTICS_RELEVANT_SYSTEM_CLASSES = %w[_User _Role].freeze

      # Build edges across the currently-loaded Parse model classes.
      #
      # When `classes:` is provided, only edges whose `from` AND `to` are both
      # in the subset are returned (strict slice — keeps the diagram focused).
      # Pass nil for the full graph.
      #
      # When MetadataRegistry has any `agent_visible` classes registered, only
      # those are walked; otherwise all `Parse::Object` descendants are walked.
      # Keeps the graph aligned with what the agent surfaces elsewhere.
      #
      # @param classes [Array<String>, nil] optional class-name subset
      # @return [Array<Hash>] edge hashes
      def build(classes: nil)
        subset = classes && classes.map(&:to_s)
        edges = []

        candidate_classes.each do |klass|
          next unless klass.respond_to?(:parse_class)
          parse_class = klass.parse_class

          if klass.respond_to?(:references)
            klass.references.each do |field, target|
              edges << {
                from: target.to_s,
                to: parse_class,
                via: "#{parse_class}.#{field}",
                cardinality: "1:N",
                kind: :belongs_to,
              }
            end
          end

          if klass.respond_to?(:relations)
            klass.relations.each do |key, target|
              # has_many :through => :relation stores the Ruby key in
              # `relations`, but `field_map` carries the on-the-wire camelCase
              # column name (respecting an explicit `field:` override). The
              # LLM needs the wire name to build `where:` / `include:` clauses
              # against the actual column.
              wire = klass.respond_to?(:field_map) ? (klass.field_map[key]&.to_s || key.to_s) : key.to_s
              edges << {
                from: parse_class,
                to: target.to_s,
                via: "#{parse_class}.#{wire}",
                cardinality: "N:M",
                kind: :relation,
              }
            end
          end
        end

        edges.uniq! { |e| [e[:from], e[:to], e[:via]] }
        return edges unless subset
        edges.select { |e| subset.include?(e[:from]) && subset.include?(e[:to]) }
      end

      # Render edges as a compact ASCII diagram. Empty graph returns a
      # one-line placeholder. Edges with components that don't match the
      # SAFE_IDENTIFIER / SAFE_VIA shapes are dropped before rendering so the
      # resulting text is always alphanumeric/dot-only — closes a theoretical
      # prompt-injection channel if any future code path admits attacker
      # influence into class or field names.
      #
      # @param edges [Array<Hash>] edge hashes from #build
      # @return [String] aligned, one-edge-per-line diagram
      def to_ascii(edges)
        safe = edges.select do |e|
          e[:from].to_s.match?(SAFE_IDENTIFIER) &&
            e[:to].to_s.match?(SAFE_IDENTIFIER) &&
            e[:via].to_s.match?(SAFE_VIA)
        end
        return "(no class relations defined)" if safe.empty?
        max_from = safe.map { |e| e[:from].length }.max
        max_to = safe.map { |e| e[:to].length }.max
        safe.map do |e|
          "#{e[:from].ljust(max_from)} ─#{e[:cardinality]}→ #{e[:to].ljust(max_to)}  (#{e[:via]})"
        end.join("\n")
      end

      # For a single Parse class, return its incoming and outgoing edges in a
      # form suitable for embedding inside an enriched schema. Pass a
      # pre-computed `edges` array to avoid re-walking the descendants on each
      # call when enriching many schemas at once.
      #
      # @param class_name [String] Parse class name
      # @param edges [Array<Hash>, nil] pre-built edges
      # @return [Hash] `{outgoing: [...], incoming: [...]}`
      def edges_for(class_name, edges = nil)
        edges ||= build
        {
          outgoing: edges.select { |e| e[:from] == class_name },
          incoming: edges.select { |e| e[:to] == class_name },
        }
      end

      private

      # Resolve the model classes to walk for graph building. When any class
      # has opted in via `agent_visible`, use that explicit set (and trust the
      # user's choice — system classes are allowed if marked visible).
      # Otherwise default to all loaded Parse::Object descendants minus the
      # `_`-prefixed Parse internals other than `_User`/`_Role` — matches the
      # guidance in the `explore_database` prompt and prevents the relation
      # graph from advertising `_Session`, `_Audience`, `_Idempotency`, etc.
      def candidate_classes
        return MetadataRegistry.visible_classes if MetadataRegistry.has_visible_classes?

        Parse::Object.descendants.reject do |klass|
          name = klass.respond_to?(:parse_class) ? klass.parse_class.to_s : klass.name.to_s
          name.start_with?("_") && !ANALYTICS_RELEVANT_SYSTEM_CLASSES.include?(name)
        end
      end
    end
  end
end
