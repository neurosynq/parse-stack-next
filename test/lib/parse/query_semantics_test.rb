# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Query compilation and execution semantics: constraints on one field all
# apply, OR / AND composition keeps every constraint, limit(0) returns no
# rows, auto-paging is stable under ties, aggregate helpers group the rows
# the query selects, and fetch helpers do not change the query.
class QuerySemanticsTest < Minitest::Test
  class SemArtist < Parse::Object
    parse_class "SemArtist"
    property :name, :string
  end

  class SemSong < Parse::Object
    parse_class "SemSong"
    property :plays, :integer
    property :title, :string
    belongs_to :artist, as: :sem_artist
  end

  FakeResponse = Struct.new(:results, :error) do
    def error?
      !error.nil?
    end
  end

  # Records find / aggregate requests; serves pages from a block.
  class FakeClient
    attr_reader :finds, :pipelines

    def initialize(&pager)
      @pager = pager || ->(_q) { [] }
      @finds = []
      @pipelines = []
    end

    def find_objects(_table, query, **)
      @finds << query
      Parse::Response.new({ "results" => @pager.call(query) })
    end

    def aggregate_pipeline(_table, pipeline, **)
      @pipelines << pipeline
      Parse::Response.new({ "results" => [] })
    end
  end

  def with_client(query, client)
    query.define_singleton_method(:client) { client }
    query
  end

  def where_of(query)
    JSON.parse(query.compile_where.to_json)
  end

  # ---- same-field constraints ------------------------------------------------

  def test_equality_and_operator_on_one_field_both_apply
    assert_equal({ "plays" => { "$eq" => 5, "$gt" => 1 } }, where_of(SemSong.query(:plays => 5, :plays.gt => 1)))
    assert_equal({ "plays" => { "$gt" => 1, "$eq" => 5 } }, where_of(SemSong.query(:plays.gt => 1).where(:plays => 5)))
    assert_equal({ "plays" => { "$gt" => 1, "$lt" => 10 } }, where_of(SemSong.query(:plays.gt => 1, :plays.lt => 10)))
  end

  def test_conflicting_constraints_on_one_field_combine_with_and
    assert_equal({ "plays" => { "$gt" => 1 }, "$and" => [{ "plays" => { "$gt" => 10 } }] },
                 where_of(SemSong.query(:plays.gt => 1).where(:plays.gt => 10)))
    assert_equal({ "plays" => 1, "$and" => [{ "plays" => 2 }] },
                 where_of(SemSong.query(:plays => 1).where(:plays => 2)))
    assert_equal({ "plays" => { "$in" => [1, 2] }, "$and" => [{ "plays" => { "$in" => [3] } }] },
                 where_of(SemSong.query(:plays.in => [1, 2]).where(:plays.in => [3])))
  end

  def test_two_regular_expressions_are_never_merged
    where = where_of(SemSong.query(:title.like => "a").where(:title.starts_with => "b"))
    assert_equal({ "$regex" => "a" }, where["title"].slice("$regex"))
    assert_equal 1, where["$and"].size
    assert_equal "^b", where["$and"].first["title"]["$regex"]
  end

  def test_identical_constraints_collapse
    assert_equal({ "plays" => 3 }, where_of(SemSong.query(:plays => 3).where(:plays => 3)))
  end

  # ---- OR / AND composition --------------------------------------------------

  def test_or_where_keeps_constraints_added_beside_an_existing_or
    q = SemSong.query(:plays.gt => 150).or_where(:plays.lt => 5).where(:title => "x").or_where(:plays => 50)
    expected = { "$or" => [
      { "$or" => [{ "plays" => { "$gt" => 150 } }, { "plays" => { "$lt" => 5 } }], "title" => "x" },
      { "plays" => 50 },
    ] }
    assert_equal expected, where_of(q)
  end

  def test_or_where_still_extends_a_plain_or
    q = SemSong.query(:plays => 1) | SemSong.query(:plays => 2) | SemSong.query(:plays => 3)
    assert_equal({ "$or" => [{ "plays" => 1 }, { "plays" => 2 }, { "plays" => 3 }] }, where_of(q))
  end

  def test_query_and_keeps_every_or
    q = Parse::Query.and(SemSong.query(:plays => 1) | SemSong.query(:plays => 2),
                         SemSong.query(:title => "a") | SemSong.query(:title => "b"))
    where = where_of(q)
    assert_equal [{ "plays" => 1 }, { "plays" => 2 }], where["$or"]
    assert_equal [{ "$or" => [{ "title" => "a" }, { "title" => "b" }] }], where["$and"]
  end

  # ---- limit(0) --------------------------------------------------------------

  def test_limit_zero_returns_no_rows_without_a_request
    client = FakeClient.new { |_q| [{ "objectId" => "a" }] }
    q = with_client(SemSong.query.limit(0), client)
    assert_equal [], q.results
    seen = []
    q.results { |row| seen << row }
    assert_equal [], seen
    assert_empty client.finds
    assert_equal 0, SemSong.query.limit(0).compile(encode: false)[:limit]
    assert_equal 0, SemSong.query.limit(-5).compile(encode: false)[:limit]
  end

  # ---- auto-paging -----------------------------------------------------------

  def test_auto_paging_orders_by_object_id_last
    rows = (0...250).map { |i| { "objectId" => format("id%04d", i), "className" => "SemSong" } }
    client = FakeClient.new { |q| rows[q["skip"] || 0, q["limit"]] || [] }
    result = with_client(SemSong.query.order(:plays.desc).limit(:max), client).results(raw: true)
    assert_equal 250, result.size
    assert(client.finds.all? { |f| f["order"] == "-plays,objectId" })

    client = FakeClient.new { |q| rows[q["skip"] || 0, q["limit"]] || [] }
    with_client(SemSong.query.limit(:max), client).results(raw: true)
    assert(client.finds.all? { |f| f["order"] == "objectId" })

    client = FakeClient.new { |q| rows[q["skip"] || 0, q["limit"]] || [] }
    with_client(SemSong.query.order(:objectId.desc).limit(:max), client).results(raw: true)
    assert(client.finds.all? { |f| f["order"] == "-objectId" })
  end

  # ---- aggregate helpers -----------------------------------------------------

  def stage_names(pipeline)
    pipeline.map { |stage| stage.keys.first }
  end

  def test_sum_applies_skip_before_group
    client = FakeClient.new
    with_client(SemSong.query(:plays.gt => 2).skip(10), client).sum(:plays)
    assert_equal %w[$match $skip $group], stage_names(client.pipelines.first)
  end

  def test_average_uses_order_and_limit_to_pick_rows
    client = FakeClient.new
    with_client(SemSong.query.order(:plays.desc).limit(2), client).average(:plays)
    assert_equal [{ "$sort" => { "plays" => -1 } }, { "$limit" => 2 }], client.pipelines.first.first(2)
    assert_equal "$group", client.pipelines.first.last.keys.first
  end

  def test_count_distinct_and_group_by_apply_the_window_before_group
    client = FakeClient.new
    with_client(SemSong.query.skip(10), client).count_distinct(:title)
    assert_equal %w[$skip $group $count], stage_names(client.pipelines.first)

    client = FakeClient.new
    with_client(SemSong.query.order(:plays.desc).limit(10), client).group_by(:title).count
    assert_equal %w[$sort $limit $group $project], stage_names(client.pipelines.first)
  end

  def test_order_alone_does_not_add_stages_to_a_sum
    client = FakeClient.new
    with_client(SemSong.query.order(:plays.desc), client).sum(:plays)
    assert_equal %w[$group], stage_names(client.pipelines.first)
  end

  def test_aggregate_helpers_with_limit_zero_make_no_request
    client = FakeClient.new
    q = with_client(SemSong.query.limit(0), client)
    assert_nil q.sum(:plays)
    assert_equal 0, q.count_distinct(:title)
    assert_equal({}, q.group_by(:title).count)
    assert_empty client.pipelines
  end

  # ---- fetch helpers ---------------------------------------------------------

  def test_first_does_not_change_the_query
    client = FakeClient.new { |_q| [{ "objectId" => "a", "className" => "SemSong" }] }
    q = with_client(SemSong.query.limit(50), client)
    q.first
    q.first(:plays => 3)
    assert_equal 50, q.instance_variable_get(:@limit)
    assert_equal({}, q.compile_where)
    q.results
    assert_equal [1, 1, 50], client.finds.map { |f| f["limit"] }
  end

  def test_latest_and_last_updated_with_an_existing_order
    client = FakeClient.new { |_q| [{ "objectId" => "a", "className" => "SemSong" }] }
    q = with_client(SemSong.query.order(:title), client)
    q.latest
    q.last_updated(2)
    assert_equal ["-createdAt,title", "-updatedAt,title"], client.finds.map { |f| f["order"] }
    assert_equal ["title"], q.instance_variable_get(:@order).map { |o| o.field.to_s }

    client = FakeClient.new { |_q| [] }
    with_client(SemSong.query.order(:created_at.asc), client).latest
    assert_equal "-createdAt", client.finds.first["order"]
  end

  # ---- pointers and list values ----------------------------------------------

  def test_bare_object_id_on_a_pointer_uses_storage_form_in_aggregates
    q = SemSong.query
    converted = q.send(:convert_constraints_for_aggregation, { "artist" => { "$ne" => "A1" } })
    assert_equal({ "_p_artist" => { "$ne" => "SemArtist$A1" } }, converted)
    converted = q.send(:convert_constraints_for_aggregation, { "artist" => "A1" })
    assert_equal({ "_p_artist" => "SemArtist$A1" }, converted)
    converted = q.send(:convert_constraints_for_aggregation, { "artist" => { "$ne" => "SemArtist$A1" } })
    assert_equal({ "_p_artist" => { "$ne" => "SemArtist$A1" } }, converted)
  end

  def test_bare_object_id_on_a_pointer_uses_storage_form_on_mongo_direct
    converted = SemSong.query.send(:convert_constraints_for_direct_mongodb,
                                   { "artist" => { "$ne" => "A1", "$in" => ["A2"] } })
    assert_equal({ "_p_artist" => { "$ne" => "SemArtist$A1", "$in" => ["SemArtist$A2"] } }, converted)
  end

  def test_set_and_range_values_are_expanded_for_list_operators
    assert_equal({ "plays" => { "$in" => [1, 2] } }, where_of(SemSong.query(:plays.in => Set[1, 2])))
    assert_equal({ "plays" => { "$in" => [1, 2, 3] } }, where_of(SemSong.query(:plays.in => 1..3)))
    assert_equal({ "plays" => { "$nin" => [4, 5] } }, where_of(SemSong.query(:plays.nin => 4...6)))
    assert_raises(ArgumentError) { SemSong.query(:plays.in => (1..)).compile_where }
  end
end
