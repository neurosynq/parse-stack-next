require_relative "../../test_helper"
require_relative "../../support/snapshot_helper"
require "parse/atlas_search"
require "minitest/autorun"

# Snapshot regression coverage for Parse::AtlasSearch::SearchBuilder. The
# `$search` stage is the first stage of an Atlas Search aggregation pipeline
# and must keep a very specific shape — MongoDB rejects anything else, and
# the surrounding ACL injection assumes `$search` is stage 0. Snapshots here
# pin the builder's compiled stage independent of corpus/index state.
class AtlasSearchBuilderSnapshotTest < Minitest::Test
  GROUP = "atlas_search_builder".freeze

  def builder
    Parse::AtlasSearch::SearchBuilder.new(index_name: "test_index")
  end

  def test_simple_text
    stage = builder.text(query: "ruby", path: "title").build
    assert_snapshot(stage, name: "simple_text", group: GROUP)
  end

  def test_text_with_fuzzy_and_score
    stage = builder.text(
      query: "ruby",
      path: ["title", "body"],
      fuzzy: { maxEdits: 2, prefixLength: 1 },
      score: { boost: { value: 2 } },
    ).build
    assert_snapshot(stage, name: "text_fuzzy_score", group: GROUP)
  end

  def test_phrase_with_slop
    stage = builder.phrase(query: "open source", path: "body", slop: 2).build
    assert_snapshot(stage, name: "phrase_with_slop", group: GROUP)
  end

  def test_autocomplete_with_fuzzy
    stage = builder.autocomplete(
      query: "rub",
      path: "title",
      fuzzy: { maxEdits: 1 },
      token_order: "sequential",
    ).build
    assert_snapshot(stage, name: "autocomplete_fuzzy", group: GROUP)
  end

  def test_range_numeric
    stage = builder.range(path: "likes", gte: 10, lt: 100).build
    assert_snapshot(stage, name: "range_numeric", group: GROUP)
  end

  def test_multi_operator_auto_compound
    # When more than one operator is added, the builder folds them into a
    # compound.must array. Snapshot pins that auto-folding.
    stage = builder
      .text(query: "ruby", path: "title")
      .range(path: "likes", gte: 10)
      .build
    assert_snapshot(stage, name: "multi_op_auto_compound", group: GROUP)
  end

  def test_build_compound_explicit
    b = builder
    must = b.text(query: "ruby", path: "title")
    # Take just the operator hash for `must`; build_compound expects op-shaped
    # hashes, which is why SearchBuilder exposes operator builders that also
    # return self. Use a fresh builder for each branch to isolate state.
    must_op = { "text" => { "query" => "ruby", "path" => "title" } }
    should_op = { "phrase" => { "query" => "open source", "path" => "body" } }
    must_not_op = { "exists" => { "path" => "archived_at" } }

    stage = builder.build_compound(
      must: [must_op],
      should: [should_op],
      must_not: [must_not_op],
      minimum_should_match: 1,
    )
    assert_snapshot(stage, name: "build_compound_explicit", group: GROUP)
  end

  def test_with_highlight_and_count
    stage = builder
      .text(query: "ruby", path: "title")
      .with_highlight(path: "title")
      .with_count(type: "total")
      .build
    assert_snapshot(stage, name: "with_highlight_and_count", group: GROUP)
  end

  # --- additional operator coverage ---------------------------------------

  def test_wildcard
    stage = builder.wildcard(query: "rub*", path: "title").build
    assert_snapshot(stage, name: "wildcard", group: GROUP)
  end

  def test_regex
    stage = builder.regex(query: "ru[bt]y", path: "title", allow_analyzed_field: true).build
    assert_snapshot(stage, name: "regex", group: GROUP)
  end

  def test_text_with_synonyms
    stage = builder.text(query: "ruby", path: "title", synonyms: "languages").build
    assert_snapshot(stage, name: "text_synonyms", group: GROUP)
  end

  def test_compound_filter_branch
    # The `filter:` branch of compound is the no-scoring filter; previous
    # snapshot only covered must/should/mustNot.
    text_op = { "text" => { "query" => "ruby", "path" => "title" } }
    filter_op = { "range" => { "path" => "likes", "gte" => 10 } }
    stage = builder.build_compound(must: [text_op], filter: [filter_op])
    assert_snapshot(stage, name: "build_compound_filter", group: GROUP)
  end

  def test_near_geo
    origin = { "type" => "Point", "coordinates" => [-122.4194, 37.7749] }
    stage = builder.near(path: "location", origin: origin, pivot: 1000).build
    assert_snapshot(stage, name: "near_geo", group: GROUP)
  end

  def test_geo_within_box
    bl = { "type" => "Point", "coordinates" => [-123.0, 37.0] }
    tr = { "type" => "Point", "coordinates" => [-122.0, 38.0] }
    stage = builder.geo_within(path: "location", box: [bl, tr]).build
    assert_snapshot(stage, name: "geo_within_box", group: GROUP)
  end

  def test_geo_shape_intersects
    polygon = {
      "type" => "Polygon",
      "coordinates" => [[[-122.0, 37.0], [-122.0, 38.0], [-123.0, 38.0], [-123.0, 37.0], [-122.0, 37.0]]],
    }
    stage = builder.geo_shape(path: "location", relation: :intersects, geometry: polygon).build
    assert_snapshot(stage, name: "geo_shape_intersects", group: GROUP)
  end
end
