# encoding: UTF-8
# frozen_string_literal: true

# Parse::GraphQL — schema introspection → graphql-ruby type generation.
#
# The `graphql` gem is an OPTIONAL dependency. It is intentionally NOT a
# runtime dependency of parse-stack: users who never opt into GraphQL
# codegen should not pay the load cost. Mirror the
# `Parse::MongoDB.gem_available?` soft-require pattern.
#
# Usage:
#   require "parse/graphql"
#   raise "install the 'graphql' gem first" unless Parse::GraphQL.available?
#   SongType = Parse::GraphQL::TypeGenerator.generate(Song)
#
# v1 scope: type generation only. Resolvers (query/mutation passthrough,
# Loaders, Node interface, connections) are intentionally deferred — see
# TODO.md §7. The generated types work with default graphql-ruby field
# resolution because Parse::Object subclasses already expose typed
# accessors (`song.album`, `band.fans`).

module Parse
  module GraphQL
    class << self
      # @return [Boolean] true if the `graphql` gem can be loaded.
      def available?
        return @gem_available if defined?(@gem_available)
        @gem_available = begin
          require "graphql"
          true
        rescue LoadError
          false
        end
      end

      # Force-reset the cached availability flag. Test-only.
      # @!visibility private
      def reset!
        remove_instance_variable(:@gem_available) if defined?(@gem_available)
      end
    end
  end
end

if Parse::GraphQL.available?
  require_relative "graphql/scalars"
  require_relative "graphql/type_generator"
end
