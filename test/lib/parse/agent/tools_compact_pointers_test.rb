# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Unit tests for Tools.compact_pointers! — the pass that strips
# Parse-on-Mongo storage-form `_p_<field>: "<ClassName>$<objectId>"` rows
# into `<field>: "<objectId>"` and returns a `{ field => className }` map
# for the response envelope.
class ToolsCompactPointersTest < Minitest::Test
  T = Parse::Agent::Tools

  def test_compresses_invariant_class_column
    rows = [
      { "_p_author" => "_User$alice1", "title" => "a" },
      { "_p_author" => "_User$bob222", "title" => "b" },
      { "_p_author" => "_User$carol3", "title" => "c" },
    ]
    map = T.compact_pointers!(rows)
    assert_equal({ "author" => "_User" }, map)
    assert_equal "alice1", rows[0]["author"]
    assert_equal "bob222", rows[1]["author"]
    refute rows[0].key?("_p_author"), "original storage column must be removed"
  end

  def test_returns_empty_map_when_no_pointer_columns
    rows = [{ "title" => "a" }, { "title" => "b" }]
    map = T.compact_pointers!(rows)
    assert_empty map
    assert_equal "a", rows[0]["title"]
  end

  def test_preserves_value_when_value_doesnt_match_pointer_shape
    # `_p_author` present but value doesn't look like ClassName$id —
    # don't touch it (could be corrupt data, definitely not a pointer).
    rows = [{ "_p_author" => "not-a-pointer", "title" => "a" }]
    map = T.compact_pointers!(rows)
    assert_empty map
    assert_equal "not-a-pointer", rows[0]["_p_author"]
  end

  def test_skips_column_with_mixed_classes
    # When the same `_p_*` column has values referencing two different
    # classes (anomalous), leaving it uncompressed avoids data loss.
    rows = [
      { "_p_subject" => "_User$x", "n" => 1 },
      { "_p_subject" => "Team$y",  "n" => 2 },
    ]
    map = T.compact_pointers!(rows)
    assert_empty map, "mixed-class column must not be added to the pointer map"
    assert_equal "_User$x", rows[0]["_p_subject"]
    assert_equal "Team$y",  rows[1]["_p_subject"]
  end

  def test_skips_column_with_bare_collision
    # If the row has BOTH `_p_author` and `author`, renaming would
    # shadow the existing value — leave it alone.
    rows = [
      { "_p_author" => "_User$x", "author" => "preset", "n" => 1 },
    ]
    map = T.compact_pointers!(rows)
    assert_empty map
    assert_equal "_User$x", rows[0]["_p_author"]
    assert_equal "preset",  rows[0]["author"]
  end

  def test_walks_into_nested_arrays_and_hashes
    # $lookup output appears as nested arrays. The walker should
    # observe and compress those too.
    rows = [
      {
        "_id"     => "groupA",
        "joined"  => [
          { "_p_author" => "_User$abc", "n" => 1 },
          { "_p_author" => "_User$def", "n" => 2 },
        ],
      },
    ]
    map = T.compact_pointers!(rows)
    assert_equal({ "author" => "_User" }, map)
    assert_equal "abc", rows[0]["joined"][0]["author"]
    assert_equal "def", rows[0]["joined"][1]["author"]
  end

  def test_multiple_distinct_pointer_columns_collected
    rows = [
      { "_p_author" => "_User$a1", "_p_project" => "Project$p1" },
      { "_p_author" => "_User$a2", "_p_project" => "Project$p2" },
    ]
    map = T.compact_pointers!(rows)
    assert_equal({ "author" => "_User", "project" => "Project" }, map)
    assert_equal "a1", rows[0]["author"]
    assert_equal "p1", rows[0]["project"]
  end

  def test_null_value_passes_through_doesnt_pollute_map
    rows = [
      { "_p_author" => "_User$a1", "_p_assignee" => nil },
      { "_p_author" => "_User$a2", "_p_assignee" => "_User$b1" },
    ]
    map = T.compact_pointers!(rows)
    # `author` is invariant (_User) — compressed.
    # `assignee` had a nil and a _User — only one observed class, also
    # compressed. Nils pass through unchanged.
    assert_equal "_User", map["author"]
    assert_equal "_User", map["assignee"]
    assert_nil rows[0]["assignee"]
    assert_equal "b1", rows[1]["assignee"]
  end

  def test_preserves_symbol_key_type_for_symbol_keyed_input
    rows = [{ _p_author: "_User$a1", n: 1 }]
    map = T.compact_pointers!(rows)
    assert_equal({ "author" => "_User" }, map)
    # Symbol-keyed hashes stay Symbol-keyed after rewrite.
    assert_equal "a1", rows[0][:author]
    refute rows[0].key?(:_p_author)
  end

  # ============================================================
  # Wire-level — aggregate runs the compaction by default
  # ============================================================

  class FakeAggregateClient
    def initialize(rows)
      @rows = rows
    end

    def aggregate_pipeline(_class, _pipeline, **_opts)
      response = Object.new
      rows = @rows
      response.define_singleton_method(:success?) { true }
      response.define_singleton_method(:results)  { rows }
      response.define_singleton_method(:error)    { nil }
      response
    end
  end

  def build_agent(rows)
    unless Parse::Client.client?
      Parse.setup(
        server_url: "http://localhost:1337/parse",
        application_id: "test-app-id",
        api_key: "test-api-key",
      )
    end
    agent = Parse::Agent.new
    agent.instance_variable_set(:@client, FakeAggregateClient.new(rows))
    agent
  end

  def test_aggregate_compacts_pointers_by_default
    rows = [
      { "_p_author" => "_User$alice1", "title" => "a" },
      { "_p_author" => "_User$bob222", "title" => "b" },
    ]
    agent = build_agent(rows)
    result = T.aggregate(agent, class_name: "Capture",
                                pipeline: [{ "$match" => { "title" => { "$exists" => true } } }])
    assert_equal({ "author" => "_User" }, result[:pointer_classes])
    assert_equal "alice1", result[:results][0]["author"]
    refute result[:results][0].key?("_p_author")
  end

  def test_aggregate_skips_compaction_when_compact_pointers_false
    rows = [
      { "_p_author" => "_User$alice1", "title" => "a" },
    ]
    agent = build_agent(rows)
    result = T.aggregate(agent, class_name: "Capture",
                                pipeline: [{ "$match" => { "title" => { "$exists" => true } } }],
                                compact_pointers: false)
    refute result.key?(:pointer_classes),
           "envelope must NOT contain pointer_classes when compact_pointers: false"
    assert_equal "_User$alice1", result[:results][0]["_p_author"]
  end

  def test_aggregate_omits_pointer_classes_when_no_columns_compress
    rows = [{ "title" => "a", "n" => 1 }]
    agent = build_agent(rows)
    result = T.aggregate(agent, class_name: "Capture",
                                pipeline: [{ "$match" => { "title" => { "$exists" => true } } }])
    refute result.key?(:pointer_classes),
           "envelope must NOT carry pointer_classes when nothing was compressed"
  end
end
