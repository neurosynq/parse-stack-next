# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/graphql"

# Static type-shape contract for Parse::GraphQL::TypeGenerator.
# v1 emits TYPE shape only — no resolvers, no Loaders, no Relay
# connections. Default graphql-ruby field resolution invokes the
# same-named method on the underlying Parse::Object, which already
# exposes typed accessors (`song.album`, `band.fans`, etc.).
#
# These tests guard:
#  - scalar field type mapping (string/int/float/date/file/geopoint)
#  - belongs_to → strongly-typed object field via lazy registry lookup
#  - has_many through :array | :relation | :query → `[Type]` plain list
#  - has_one → strongly-typed object field
#  - ACL fields are omitted
#  - cross-class lookup via shared registry
class GraphQLTypeGeneratorTest < Minitest::Test
  def self.fixture_models_loaded?
    defined?(@fixture_loaded) && @fixture_loaded
  end

  # Define fixture models once. Class-eval is intentional — these are
  # test-only schema and must not leak into other test files that
  # subclass Parse::Object.
  unless defined?(GqlGenSong)
    class GqlGenAlbum < Parse::Object
      parse_class "GqlGenAlbum"
      property :title, :string
      property :released, :date
    end

    class GqlGenArtist < Parse::Object
      parse_class "GqlGenArtist"
      property :name, :string
      property :debut_year, :integer
      property :rating, :float
      property :active, :boolean
      property :avatar, :file
      property :hometown, :geopoint
      property :tags, :array
      has_many :songs, as: :gql_gen_song
      has_many :albums, through: :relation, as: :gql_gen_album
      has_many :coauthors, through: :array, as: :gql_gen_artist
    end

    class GqlGenSong < Parse::Object
      parse_class "GqlGenSong"
      property :title, :string
      property :duration, :integer
      belongs_to :album, as: :gql_gen_album
      belongs_to :artist, as: :gql_gen_artist
      has_one :latest_remix, as: :gql_gen_song, field: :original_song
    end
  end

  # ----------------------------------------------------------------
  # Smoke
  # ----------------------------------------------------------------

  def test_gem_is_available_in_test_env
    assert Parse::GraphQL.available?,
           "graphql gem must be loadable in dev/test env (development_dependency)"
  end

  MODELS = [GqlGenAlbum, GqlGenArtist, GqlGenSong].freeze

  def generated
    @generated ||= Parse::GraphQL::TypeGenerator.generate_all(MODELS)
  end

  def test_generate_returns_graphql_schema_object_subclass
    type = generated["GqlGenAlbum"]
    assert type < ::GraphQL::Schema::Object
    assert_equal "GqlGenAlbum", type.graphql_name
  end

  def test_generate_raises_on_non_parse_object
    assert_raises(ArgumentError) do
      Parse::GraphQL::TypeGenerator.generate(Object)
    end
  end

  # ----------------------------------------------------------------
  # Scalar field mapping
  # ----------------------------------------------------------------

  def test_scalar_field_type_mapping
    fields = generated["GqlGenArtist"].fields
    assert_equal ::GraphQL::Types::String, fields["name"].type.unwrap
    assert_equal ::GraphQL::Types::Int, fields["debutYear"].type.unwrap
    assert_equal ::GraphQL::Types::Float, fields["rating"].type.unwrap
    assert_equal ::GraphQL::Types::Boolean, fields["active"].type.unwrap
  end

  def test_date_fields_map_to_iso8601
    type = generated["GqlGenAlbum"]
    assert_equal ::GraphQL::Types::ISO8601DateTime, type.fields["released"].type.unwrap
  end

  def test_built_in_timestamps_present_as_iso8601
    type = generated["GqlGenAlbum"]
    assert type.fields.key?("createdAt"), "createdAt field must be emitted"
    assert type.fields.key?("updatedAt"), "updatedAt field must be emitted"
    assert_equal ::GraphQL::Types::ISO8601DateTime, type.fields["createdAt"].type.unwrap
  end

  def test_id_field_emitted_as_non_null_id
    type = generated["GqlGenAlbum"]
    refute_nil type.fields["id"]
    assert_equal ::GraphQL::Types::ID, type.fields["id"].type.unwrap
    assert type.fields["id"].type.non_null?, "id must be non-null"
  end

  def test_file_field_maps_to_parse_file_object
    type = generated["GqlGenArtist"]
    assert_equal Parse::GraphQL::Types::ParseFile, type.fields["avatar"].type.unwrap
  end

  def test_geopoint_field_maps_to_parse_geopoint_object
    type = generated["GqlGenArtist"]
    assert_equal Parse::GraphQL::Types::ParseGeoPoint, type.fields["hometown"].type.unwrap
  end

  def test_acl_field_is_omitted
    type = generated["GqlGenAlbum"]
    refute type.fields.key?("ACL"),
           "ACL is internal authz metadata and must not leak into the generated schema"
    refute type.fields.key?("acl")
  end

  # ----------------------------------------------------------------
  # belongs_to → object field
  # ----------------------------------------------------------------

  def test_belongs_to_emits_typed_object_field
    song = generated["GqlGenSong"]
    album_field = song.fields["album"]
    refute_nil album_field, "belongs_to :album must emit an `album` field"
    assert_equal generated["GqlGenAlbum"], album_field.type.unwrap
  end

  def test_belongs_to_to_unregistered_target_raises
    registry = {} # empty — no targets stubbed
    err = assert_raises(RuntimeError) do
      Parse::GraphQL::TypeGenerator.generate(GqlGenSong, registry: registry)
    end
    assert_match(/no generated type found for "GqlGenAlbum"/, err.message)
  end

  # ----------------------------------------------------------------
  # has_many: all three storage modes → plain list
  # ----------------------------------------------------------------

  def test_has_many_query_emits_plain_list
    artist = generated["GqlGenArtist"]
    field = artist.fields["songs"]
    refute_nil field, "has_many :songs (query) must emit a `songs` field"
    assert_kind_of ::GraphQL::Schema::List, field.type,
                   "has_many must be a list, never a Relay connection"
    assert_equal generated["GqlGenSong"], field.type.unwrap
  end

  def test_has_many_relation_emits_plain_list
    artist = generated["GqlGenArtist"]
    field = artist.fields["albums"]
    refute_nil field, "has_many :albums (relation) must emit an `albums` field"
    assert_kind_of ::GraphQL::Schema::List, field.type
    assert_equal generated["GqlGenAlbum"], field.type.unwrap
  end

  def test_has_many_array_emits_plain_list_and_suppresses_raw_array_field
    artist = generated["GqlGenArtist"]
    field = artist.fields["coauthors"]
    refute_nil field, "has_many through: :array must emit a typed list field"
    assert_kind_of ::GraphQL::Schema::List, field.type
    # The raw camelCase array column must NOT also be emitted as a
    # JSON-scalar duplicate.
    json_dupes = artist.fields.values.count do |f|
      f.graphql_name == "coauthors" && f.type.unwrap == Parse::GraphQL::Types::JSON
    end
    assert_equal 0, json_dupes,
                 "has_many :through :array must not also be emitted as a JSON scalar"
  end

  def test_raw_array_property_emits_json_scalar_with_warning
    _stderr_was = $stderr
    captured = StringIO.new
    $stderr = captured
    type = nil
    begin
      type = Parse::GraphQL::TypeGenerator.generate_all(MODELS)["GqlGenArtist"]
    ensure
      $stderr = _stderr_was
    end
    assert_equal Parse::GraphQL::Types::JSON, type.fields["tags"].type.unwrap
    assert_match(/tags.*emitting as JSON scalar/, captured.string,
      "weakly-typed :array column should warn the author")
  end

  # ----------------------------------------------------------------
  # has_one
  # ----------------------------------------------------------------

  def test_has_one_emits_typed_object_field
    song = generated["GqlGenSong"]
    field = song.fields["latestRemix"]
    refute_nil field, "has_one :latest_remix must emit a `latestRemix` field"
    assert_equal generated["GqlGenSong"], field.type.unwrap
  end

  # ----------------------------------------------------------------
  # Association metadata registry (DSL-time)
  # ----------------------------------------------------------------

  def test_has_one_associations_registry_populated_at_dsl_time
    meta = GqlGenSong.has_one_associations[:latest_remix]
    refute_nil meta, "has_one must populate has_one_associations registry"
    assert_equal "GqlGenSong", meta[:target_class]
    assert_equal :original_song, meta[:foreign_field]
  end

  def test_has_many_associations_registry_covers_all_three_storage_modes
    metas = GqlGenArtist.has_many_associations
    assert_equal "GqlGenSong", metas[:songs][:target_class]
    assert_equal :query, metas[:songs][:storage]
    assert_equal "GqlGenAlbum", metas[:albums][:target_class]
    assert_equal :relation, metas[:albums][:storage]
    assert_equal "GqlGenArtist", metas[:coauthors][:target_class]
    assert_equal :array, metas[:coauthors][:storage]
  end

  # ----------------------------------------------------------------
  # End-to-end: types compose into a real GraphQL::Schema
  # ----------------------------------------------------------------

  # Type-shape correctness ≠ schema-build correctness. Compose the
  # generated graph into a real `GraphQL::Schema` and prove
  # `to_definition` returns without raising — this catches errors
  # like missing orphan types, unreachable nodes, or cycles that
  # individual field assertions would miss.
  def test_generated_types_compose_into_a_real_graphql_schema
    types = generated
    query_root = Class.new(::GraphQL::Schema::Object) do
      graphql_name "Query"
    end
    query_root.field :song, types["GqlGenSong"], null: true
    query_root.field :artist, types["GqlGenArtist"], null: true
    query_root.field :album, types["GqlGenAlbum"], null: true

    schema = Class.new(::GraphQL::Schema)
    schema.query(query_root)
    schema.orphan_types(types.values)

    sdl = schema.to_definition
    assert_kind_of String, sdl
    assert_match(/type GqlGenSong/, sdl)
    assert_match(/type GqlGenAlbum/, sdl)
    assert_match(/type GqlGenArtist/, sdl)
  end

  unless defined?(GqlGenMyThing)
    class GqlGenMyThing < Parse::Object
      parse_class "GqlGenMyThing"
      property :name, :string
    end
    class GqlGenMy_Thing < Parse::Object
      parse_class "GqlGen_My_Thing"
      property :name, :string
    end
  end

  def test_generate_all_detects_graphql_name_collisions
    err = assert_raises(RuntimeError) do
      Parse::GraphQL::TypeGenerator.generate_all([GqlGenMyThing, GqlGenMy_Thing])
    end
    assert_match(/graphql_name collisions/, err.message)
  end
end
