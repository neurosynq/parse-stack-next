# encoding: UTF-8
# frozen_string_literal: true

# Shared GraphQL types for Parse-native shapes (File, GeoPoint) and a
# JSON scalar fallback for `:array` / `:object` columns that have no
# declared element type.
#
# Object types are preferred over scalars wherever the shape is
# stable and small: graphql-ruby's own Scalars guide explicitly warns
# that JSON scalars "completely lose all GraphQL type safety". File and
# GeoPoint both qualify — fixed two-field shapes that may grow
# additively (e.g. `content_type`, `size`) without a breaking change.
#
# Loaded only when the `graphql` gem is available — guarded by
# `Parse::GraphQL.available?` in `lib/parse/graphql.rb`.

module Parse
  module GraphQL
    module Types
      class ParseFile < ::GraphQL::Schema::Object
        graphql_name "ParseFile"
        description "A Parse File reference (URL + filename)."
        field :url, String, null: false
        field :name, String, null: true
      end

      class ParseGeoPoint < ::GraphQL::Schema::Object
        graphql_name "ParseGeoPoint"
        description "A Parse GeoPoint (latitude/longitude in degrees, WGS84)."
        field :latitude, Float, null: false
        field :longitude, Float, null: false
      end

      # Fallback for `:array` / `:object` columns with no element type.
      # Emits a warning at codegen time when used so authors know to
      # narrow the type if possible. Subscribers needing typed list
      # elements should declare `belongs_to` / `has_many` instead of
      # a raw `property :foo, :array`.
      class JSON < ::GraphQL::Schema::Scalar
        graphql_name "JSON"
        description "Arbitrary JSON value (object, array, scalar, or null)."

        def self.coerce_input(value, _ctx)
          value
        end

        def self.coerce_result(value, _ctx)
          value
        end
      end
    end
  end
end
