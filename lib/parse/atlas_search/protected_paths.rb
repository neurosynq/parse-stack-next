# encoding: UTF-8
# frozen_string_literal: true

require_relative "../clp_scope"

module Parse
  module AtlasSearch
    # Shared "does this path touch a protected field" logic for every
    # Atlas Search and vector search entry point.
    #
    # Stripping a protected field from the RESULT rows does not stop it
    # from deciding which documents MATCH, how they RANK, or which rows a
    # filter keeps. A scoped caller that can name a protected field in a
    # `$search` path, a highlight, an autocomplete field, a sort, or a
    # `$match` filter key can test guesses against its value. These
    # helpers find every such reference so the entry points can refuse
    # the call with {Parse::CLPScope::Denied}.
    #
    # Path comparison rules:
    # * A String or Symbol path is reduced to its first dotted segment,
    #   with a `_p_` storage prefix removed (`_p_owner` counts as `owner`,
    #   `secret.sub` counts as `secret`). The storage columns
    #   `_created_at` / `_updated_at` / `_id` map to `createdAt` /
    #   `updatedAt` / `objectId`.
    # * An Array path touches a protected field when any element does.
    # * A `{ "value" => ..., "multi" => ... }` path object is judged by
    #   its `value`.
    # * A `{ "wildcard" => ... }` path object, or any other non-String
    #   path, is treated as touching every field.
    #
    # Every check is a no-op for a master resolution, a nil resolution,
    # or an empty protected set.
    module ProtectedPaths
      # Storage-form column names that differ from their Parse field name.
      STORAGE_ALIASES = {
        "_created_at" => "createdAt",
        "_updated_at" => "updatedAt",
        "_id" => "objectId",
      }.freeze

      # Query operators whose value is a list of sub-filters.
      LOGICAL_OPERATORS = %w[$and $or $nor].freeze

      # Sentinel yielded for a reference that reaches every field
      # (a wildcard path, a queryString query).
      ALL_FIELDS = :__all_fields__

      module_function

      # @return [Boolean] true when the scope is subject to protectedFields.
      def enforce?(resolution, protected_fields)
        return false if resolution.nil?
        return false if resolution.respond_to?(:master?) && resolution.master?
        !(protected_fields.nil? || protected_fields.empty?)
      end

      # The Parse field name a single String path addresses.
      # @return [String, nil]
      def root_field(path)
        head = path.to_s.split(".").first.to_s
        return nil if head.empty?
        head = STORAGE_ALIASES.fetch(head, head)
        head = head.delete_prefix("_p_") if head.start_with?("_p_") && head.length > 3
        head
      end

      # Whether `path` touches a protected field.
      #
      # @param path [String, Symbol, Array, Hash, Object] an Atlas path.
      # @param protected_fields [Set<String>, Array<String>]
      # @return [Boolean]
      def touches?(path, protected_fields)
        return false if protected_fields.nil? || protected_fields.empty?
        case path
        when String, Symbol
          protected_fields.include?(root_field(path))
        when Array
          path.any? { |p| touches?(p, protected_fields) }
        when Hash
          value = path.key?("value") ? path["value"] : path[:value]
          has_wildcard = path.key?("wildcard") || path.key?(:wildcard)
          return true if has_wildcard || value.nil?
          touches?(value, protected_fields)
        else
          true
        end
      end

      # Refuse when any of `paths` touches a protected field.
      #
      # @param paths [Object] a single path or an Array of paths.
      # @param what [String] used in the error message ("search path",
      #   "highlight path", ...).
      # @raise [Parse::CLPScope::Denied]
      def assert_paths_allowed!(paths, protected_fields, resolution, collection_name: nil,
                                                                     method_name: "Parse::AtlasSearch.search",
                                                                     what: "path")
        return unless enforce?(resolution, protected_fields)
        list = paths.is_a?(Array) ? paths : [paths]
        hit = list.find { |p| touches?(p, protected_fields) }
        return if hit.nil? && !list.empty?
        raise_denied!(collection_name, method_name, what, hit.nil? ? ALL_FIELDS : hit)
      end

      # Walk a `$search` / `$searchMeta` body (or a whole stage) and
      # refuse any path, sort key, or query-string reference that touches
      # a protected field. Operators nest freely (compound
      # must/should/filter/mustNot, embeddedDocument, facet operators,
      # score functions), so every `path` / `defaultPath` value at any
      # depth is checked.
      #
      # @raise [Parse::CLPScope::Denied]
      def assert_search_stage_allowed!(stage, protected_fields, resolution, collection_name: nil,
                                                                             method_name: "Parse::AtlasSearch.search_with_stage")
        return unless enforce?(resolution, protected_fields)
        each_search_reference(stage) do |ref|
          next unless ref == ALL_FIELDS || touches?(ref, protected_fields)
          raise_denied!(collection_name, method_name, "$search path", ref)
        end
        nil
      end

      # Yield every field reference in a `$search`-style body.
      # @!visibility private
      def each_search_reference(node, &block)
        case node
        when Array
          node.each { |child| each_search_reference(child, &block) }
        when Hash
          node.each do |key, value|
            case key.to_s
            when "path", "defaultPath"
              yield value
            when "sort"
              if value.is_a?(Hash)
                value.each do |sort_key, dir|
                  # `{ score: { $meta: "searchScore" } }` sorts by relevance,
                  # not by a stored field.
                  next if dir.is_a?(Hash) && (dir.key?("$meta") || dir.key?(:$meta))
                  yield sort_key
                end
              else
                each_search_reference(value, &block)
              end
            when "queryString"
              # The Lucene query syntax can name any field (`ssn:123*`),
              # so the query text reaches every field.
              yield ALL_FIELDS
              each_search_reference(value, &block)
            when "moreLikeThis"
              like = value.is_a?(Hash) ? (value["like"] || value[:like]) : nil
              Array(like).each do |doc|
                doc.is_a?(Hash) ? doc.each_key { |k| yield k } : yield(ALL_FIELDS)
              end
              each_search_reference(value, &block)
            else
              each_search_reference(value, &block)
            end
          end
        end
        nil
      end

      # Refuse a `$match` filter whose predicate KEYS (top level, and
      # inside `$and` / `$or` / `$nor` / `$not`) or `$expr` field
      # references touch a protected field. A filter decides which rows
      # survive, so filtering on a protected field is an oracle on its
      # value even when the field is stripped from the output.
      #
      # @raise [Parse::CLPScope::Denied]
      def assert_filter_allowed!(filter, protected_fields, resolution, collection_name: nil,
                                                                        method_name: "Parse::AtlasSearch.search")
        return unless enforce?(resolution, protected_fields)
        each_filter_reference(filter) do |ref|
          next unless touches?(ref, protected_fields)
          raise_denied!(collection_name, method_name, "filter field", ref)
        end
        nil
      end

      # Yield every field name a `$match` filter predicates on.
      # @!visibility private
      def each_filter_reference(node, &block)
        case node
        when Array
          node.each { |child| each_filter_reference(child, &block) }
        when Hash
          node.each do |key, value|
            k = key.to_s
            if LOGICAL_OPERATORS.include?(k) || k == "$not"
              each_filter_reference(value, &block)
            elsif k == "$expr"
              each_expr_reference(value, &block)
            elsif k.start_with?("$")
              # Other top-level operators ($text, $comment, ...) do not
              # name a stored field by key.
              next
            else
              yield k
            end
          end
        end
        nil
      end

      # Yield `$field` references inside an aggregation expression.
      # `$$VAR` references are variables, not fields.
      # @!visibility private
      def each_expr_reference(node, &block)
        case node
        when String
          yield node[1..] if node.start_with?("$") && !node.start_with?("$$") && node.length > 1
        when Array
          node.each { |child| each_expr_reference(child, &block) }
        when Hash
          node.each_value { |child| each_expr_reference(child, &block) }
        end
        nil
      end

      # @!visibility private
      def raise_denied!(collection_name, method_name, what, ref)
        detail = if ref == ALL_FIELDS
            "a #{what} that reaches every field would match on protectedFields " \
            "for the current scope; name the fields to search explicitly."
          else
            field = ref.is_a?(String) || ref.is_a?(Symbol) ? root_field(ref) : nil
            label = field ? "'#{ref}' touches protected field '#{field}'" : "#{ref.inspect} reaches every field"
            "#{what} #{label} for the current scope; matching, ranking, or " \
            "filtering on it would reveal its value."
          end
        raise Parse::CLPScope::Denied.new(collection_name, :find, "#{method_name} refused: #{detail}")
      end
    end
  end
end
