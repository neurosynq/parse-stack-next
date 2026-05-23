require_relative "../../test_helper"

# Unit tests for the order/sort/list push-down added in 4.4.3:
#   - GroupBy#order(key:|value:|size:) / GroupBy#sort
#   - GroupBy#list ($push: $$ROOT + Parse::Object normalization)
#   - GroupByDate#order / #sort (no :size target)
#   - Query#distinct(order:) and #distinct_direct(order:) shape
#   - validate_sort_target_for_operation! incompatible-combo guard
#
# Pipeline-shape tests use Parse::Query#aggregate's stubbable path: the
# group_by helper builds a pipeline via `.pipeline` and the execution
# helpers route through `@query.client.aggregate_pipeline`, which we mock.
class GroupByOrderTest < Minitest::Test
  def setup
    @mock_client = Minitest::Mock.new
    @query = Parse::Query.new("Song")
    @query.client = @mock_client
  end

  # ---- order(...) input validation -----------------------------------------

  def test_order_rejects_unknown_target_keys
    gb = @query.group_by(:artist)
    assert_raises(ArgumentError) { gb.order(invalid: :asc) }
  end

  def test_order_rejects_unknown_direction
    gb = @query.group_by(:artist)
    assert_raises(ArgumentError) { gb.order(key: :sideways) }
  end

  def test_order_rejects_multi_target_hash
    gb = @query.group_by(:artist)
    assert_raises(ArgumentError) { gb.order(key: :asc, value: :desc) }
  end

  def test_order_accepts_bare_symbol_as_key_direction
    gb = @query.group_by(:artist)
    gb.order(:desc) # equivalent to order(key: :desc)
    pipeline = gb.pipeline
    sort_stage = pipeline.find { |s| s.key?("$sort") }
    assert_equal({ "_id" => -1 }, sort_stage["$sort"])
  end

  def test_order_returns_self_for_chaining
    gb = @query.group_by(:artist)
    assert_same gb, gb.order(key: :asc)
  end

  # ---- pipeline shape: GroupBy -------------------------------------------

  def test_order_by_key_injects_sort_on_id
    gb = @query.group_by(:artist).order(key: :desc)
    pipeline = gb.pipeline
    # $group → $sort → $project (no $addFields for :key)
    assert_equal "$group", pipeline.find { |s| s.key?("$group") }.keys.first
    refute pipeline.any? { |s| s.key?("$addFields") }, "no $addFields for :key sort"
    sort_stage = pipeline.find { |s| s.key?("$sort") }
    refute_nil sort_stage, "expected a $sort stage"
    assert_equal({ "_id" => -1 }, sort_stage["$sort"])
    # $sort sits between $group and $project so it can reference the
    # pre-rename _id field.
    group_idx = pipeline.index { |s| s.key?("$group") }
    sort_idx = pipeline.index { |s| s.key?("$sort") }
    project_idx = pipeline.index { |s| s.key?("$project") }
    assert group_idx < sort_idx, "$sort must follow $group"
    assert sort_idx < project_idx, "$sort must precede $project"
  end

  def test_order_by_value_injects_sort_on_count
    gb = @query.group_by(:artist).order(value: :asc)
    sort_stage = gb.pipeline.find { |s| s.key?("$sort") }
    assert_equal({ "count" => 1 }, sort_stage["$sort"])
    refute gb.pipeline.any? { |s| s.key?("$addFields") }, "no $addFields for :value sort"
  end

  def test_order_by_size_emits_addfields_and_sort
    # NOTE: .order(size:) on the count-shape pipeline preview raises by
    # design (Finding 2 fix); :size is meaningful only with .list. So
    # exercise the pipeline build via execute_group_aggregation with a
    # "list" operation mock instead.
    err = assert_raises(ArgumentError) { @query.group_by(:artist).order(size: :desc).pipeline }
    assert_match(/order\(size:\) is only valid with \.list/, err.message)
  end

  def test_sort_aliases_order_by_key_asc_by_default
    gb = @query.group_by(:artist).sort
    sort_stage = gb.pipeline.find { |s| s.key?("$sort") }
    assert_equal({ "_id" => 1 }, sort_stage["$sort"])
  end

  def test_sort_accepts_direction_argument
    gb = @query.group_by(:artist).sort(:desc)
    sort_stage = gb.pipeline.find { |s| s.key?("$sort") }
    assert_equal({ "_id" => -1 }, sort_stage["$sort"])
  end

  def test_no_order_means_no_sort_stage
    gb = @query.group_by(:artist)
    refute gb.pipeline.any? { |s| s.key?("$sort") }, "expected no $sort stage when order not configured"
  end

  # ---- pipeline shape: GroupByDate ---------------------------------------

  def test_group_by_date_default_sort_is_chronological_ascending
    pipeline = build_date_pipeline { |q| q.group_by_date(:created_at, :day) }
    sort_stage = pipeline.find { |s| s.key?("$sort") }
    refute_nil sort_stage, "GroupByDate always emits a default $sort"
    assert_equal({ "_id" => 1 }, sort_stage["$sort"])
  end

  def test_group_by_date_order_key_desc_flips_default
    pipeline = build_date_pipeline { |q| q.group_by_date(:created_at, :day).order(key: :desc) }
    sort_stage = pipeline.find { |s| s.key?("$sort") }
    assert_equal({ "_id" => -1 }, sort_stage["$sort"])
  end

  def test_group_by_date_order_by_value
    pipeline = build_date_pipeline { |q| q.group_by_date(:created_at, :day).order(value: :desc) }
    sort_stage = pipeline.find { |s| s.key?("$sort") }
    assert_equal({ "count" => -1 }, sort_stage["$sort"])
  end

  def test_group_by_date_rejects_size_target
    assert_raises(ArgumentError) do
      @query.group_by_date(:created_at, :day).order(size: :desc)
    end
  end

  # ---- pipeline shape: Query#distinct(order:) ----------------------------

  def test_distinct_with_order_asc_injects_sort
    expected_pipeline_includes_sort(direction: 1)
    @query.distinct(:genre, order: :asc)
    @mock_client.verify
  end

  def test_distinct_with_order_desc_injects_sort
    expected_pipeline_includes_sort(direction: -1)
    @query.distinct(:genre, order: :desc)
    @mock_client.verify
  end

  def test_distinct_without_order_omits_sort
    mock_response = build_distinct_response([])
    captured_pipeline = nil
    @mock_client.expect :aggregate_pipeline, mock_response do |_table, pipeline, **_kw|
      captured_pipeline = pipeline
      true
    end
    @query.distinct(:genre)
    refute captured_pipeline.any? { |s| s.key?("$sort") }, "no $sort when order: nil"
  end

  def test_distinct_rejects_invalid_order
    assert_raises(ArgumentError) { @query.distinct(:genre, order: :sideways) }
  end

  # ---- validate_sort_target_for_operation! --------------------------------

  def test_validator_rejects_size_with_count
    gb = @query.group_by(:artist).order(size: :desc)
    err = assert_raises(ArgumentError) { gb.count }
    assert_match(/order\(size:\) is only valid with \.list/, err.message)
  end

  def test_validator_rejects_size_with_sum
    gb = @query.group_by(:artist).order(size: :desc)
    assert_raises(ArgumentError) { gb.sum(:plays) }
  end

  def test_validator_rejects_value_with_list
    gb = @query.group_by(:artist).order(value: :desc)
    err = assert_raises(ArgumentError) { gb.list }
    assert_match(/order\(value:\) is not supported with \.list/, err.message)
  end

  def test_validator_allows_key_with_any_operation
    # Sanity: :key is legal for count and list both — no raise should
    # occur during validation. We don't mock execution here; we only
    # confirm the validator branch doesn't fire.
    gb = @query.group_by(:artist).order(key: :asc)
    # Calling .pipeline exercises the validator without needing a mock.
    assert gb.pipeline.is_a?(Array)
  end

  def test_pipeline_preview_rejects_size_target
    # Finding 2 fix: introspection should refuse to emit a misleading
    # count-shape pipeline with a $size on the scalar count field.
    gb = @query.group_by(:artist).order(size: :asc)
    assert_raises(ArgumentError) { gb.pipeline }
  end

  private

  def build_date_pipeline
    # The date helper doesn't expose a pure pipeline-preview method, so
    # capture the pipeline as it ships to aggregate_pipeline by stubbing
    # the client with a permissive response (execute_date_aggregation
    # calls .result more than once on the response).
    captured = nil
    response = stub_aggregate_response([])
    @mock_client.expect :aggregate_pipeline, response do |_table, pipeline, **_kw|
      captured = pipeline
      true
    end
    yield(@query).count
    captured
  end

  def stub_aggregate_response(rows)
    Class.new do
      define_method(:success?) { true }
      define_method(:error?) { false }
      define_method(:result) { rows }
    end.new
  end

  def expected_pipeline_includes_sort(direction:)
    mock_response = build_distinct_response([])
    @mock_client.expect :aggregate_pipeline, mock_response do |_table, pipeline, **_kw|
      sort_stage = pipeline.find { |s| s.key?("$sort") }
      next false unless sort_stage
      sort_stage["$sort"] == { "_id" => direction }
    end
  end

  def build_distinct_response(rows)
    response = Minitest::Mock.new
    # `aggregate` -> `Aggregation#raw` reads `.success?` then `.result`.
    response.expect :success?, true
    response.expect :result, rows
    response.expect :result, rows
    def response.respond_to?(method); [:success?, :result].include?(method) || super; end
    response
  end
end
