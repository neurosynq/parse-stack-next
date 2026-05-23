# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Tests for the group_by, group_by_date, and distinct MCP tools added in
# Parse-Stack 4.2.1. Each test stubs the agent's Parse client so the focus
# is on pipeline construction and result-shape reformatting rather than
# round-tripping a real Parse Server.
class ToolsGroupDistinctTest < Minitest::Test
  T = Parse::Agent::Tools

  class GroupSong < Parse::Object
    parse_class "GroupSong"
    property :title, :string
    property :plays, :integer
    property :genre, :string
    property :tags, :array
    belongs_to :artist, as: :group_artist
  end

  class GroupArtist < Parse::Object
    parse_class "GroupArtist"
    property :name, :string
  end

  class GroupHiddenSong < Parse::Object
    parse_class "GroupHiddenSong"
    property :genre, :string
    agent_hidden
  end

  # Fixture with snake_case properties that camelise on the wire,
  # plus a multi-word pointer association. Used for H-4 field_map tests.
  class GroupTrack < Parse::Object
    parse_class "GroupTrack"
    property :play_count, :integer   # wire name: playCount
    property :released_at, :date     # wire name: releasedAt
    property :tags, :array
    belongs_to :author_id            # wire name: authorId (pointer stored as _p_authorId)
  end

  class GroupAuthor < Parse::Object
    parse_class "GroupAuthor"
    property :name, :string
  end

  # Fixture with a relation field (through: :relation) for the group_by_date rejection test.
  # Parse stores relations in klass.relations, not klass.fields.
  class GroupRelationSong < Parse::Object
    parse_class "GroupRelationSong"
    has_many :collaborators, through: :relation
  end

  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test", api_key: "test")
    end
    Parse::Agent::Tools.reset_registry!
    Parse::Agent.refuse_collscan = false
    @agent = Parse::Agent.new(permissions: :readonly)
    @agg_calls = []
  end

  def teardown
    Parse::Agent::Tools.reset_registry!
    Parse::Agent.refuse_collscan = false
  end

  # ---------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------

  # Find the first stage in a pipeline by its top-level operator name.
  def find_stage(pipeline, op)
    pipeline.find { |stage| stage.is_a?(Hash) && stage.keys.first.to_s == op }
  end

  def stub_aggregate(results)
    calls = @agg_calls
    fake = Object.new
    fake.define_singleton_method(:aggregate_pipeline) do |class_name, pipeline, **_opts|
      calls << [class_name, pipeline]
      r = Object.new
      r.define_singleton_method(:success?) { true }
      r.define_singleton_method(:results) { results }
      r
    end
    @agent.define_singleton_method(:client) { fake }
  end

  # ---------------------------------------------------------------------
  # Tool registration & permission level
  # ---------------------------------------------------------------------

  def test_tools_are_registered_in_TOOL_DEFINITIONS
    %i[group_by group_by_date distinct].each do |sym|
      assert T::TOOL_DEFINITIONS.key?(sym), "#{sym} must be in TOOL_DEFINITIONS"
      defn = T::TOOL_DEFINITIONS[sym]
      assert_equal sym.to_s, defn[:name]
      assert_equal "aggregate", defn[:category]
      assert defn[:description].is_a?(String) && !defn[:description].empty?
      assert defn[:parameters].is_a?(Hash)
    end
  end

  def test_tools_are_readonly_tier
    readonly = Parse::Agent::PERMISSION_LEVELS[:readonly]
    %i[group_by group_by_date distinct].each do |sym|
      assert_includes readonly, sym
    end
  end

  def test_tools_have_timeout_entries
    %i[group_by group_by_date distinct].each do |sym|
      assert T::TOOL_TIMEOUTS.key?(sym)
    end
  end

  # ---------------------------------------------------------------------
  # group_by — pipeline shape
  # ---------------------------------------------------------------------

  def test_group_by_count_default_operation
    # Stub data uses "objectId" because Parse Server's REST aggregate
    # endpoint renames $group._id → objectId in the response envelope
    # (verified against parse-server-test docker). The MongoDB pipeline
    # assertions below still use "_id" because that's the wire-format
    # key inside the $group stage we send TO Parse Server.
    stub_aggregate([
      { "objectId" => "rock",  "value" => 12 },
      { "objectId" => "jazz",  "value" => 7  },
      { "objectId" => "blues", "value" => 3  },
    ])

    result = @agent.execute(:group_by, class_name: "GroupSong", field: "genre")

    assert result[:success]
    body = result[:data]
    assert_equal "count", body[:operation]
    assert_equal 3, body[:group_count]
    assert_equal [{ key: "rock", value: 12 }, { key: "jazz", value: 7 }, { key: "blues", value: 3 }],
                 body[:groups]

    _class, pipeline = @agg_calls.first
    assert_equal({ "$group" => { "_id" => "$genre", "value" => { "$sum" => 1 } } }, find_stage(pipeline, "$group"))
    # Always appends $limit at cap+1 even without sort, so a high-
    # cardinality field doesn't return every group over the wire.
    assert_equal 201, find_stage(pipeline, "$limit")["$limit"]
    refute find_stage(pipeline, "$sort"), "no sort requested — no $sort stage"
  end

  def test_group_by_sum_requires_value_field
    stub_aggregate([])
    result = @agent.execute(:group_by, class_name: "GroupSong", field: "genre", operation: "sum")
    refute result[:success]
    assert_match(/value_field/, result[:error].to_s)
  end

  def test_group_by_sum_builds_sum_accumulator
    stub_aggregate([{ "objectId" => "rock", "value" => 5000 }])
    result = @agent.execute(:group_by, class_name: "GroupSong", field: "genre",
                            operation: "sum", value_field: "plays")
    assert result[:success], result.inspect
    _class, pipeline = @agg_calls.first
    group_stage = find_stage(pipeline, "$group")["$group"]
    assert_equal "$genre", group_stage["_id"]
    assert_equal({ "$sum" => "$plays" }, group_stage["value"])
    assert_equal "sum", result[:data][:operation]
    assert_equal "plays", result[:data][:value_field]
  end

  def test_group_by_avg_alias_is_normalized
    stub_aggregate([{ "objectId" => "rock", "value" => 200.5 }])
    result = @agent.execute(:group_by, class_name: "GroupSong", field: "genre",
                            operation: "average", value_field: "plays")
    assert result[:success]
    assert_equal "avg", result[:data][:operation]
    group_stage = find_stage(@agg_calls.first[1], "$group")["$group"]
    assert_equal({ "$avg" => "$plays" }, group_stage["value"])
  end

  def test_group_by_flatten_arrays_inserts_unwind
    stub_aggregate([{ "objectId" => "guitar", "value" => 2 }])
    @agent.execute(:group_by, class_name: "GroupSong", field: "tags",
                   flatten_arrays: true)
    _class, pipeline = @agg_calls.first
    assert_equal({ "$unwind" => "$tags" }, pipeline.first)
    assert_equal "$tags", find_stage(pipeline, "$group")["$group"]["_id"]
  end

  def test_group_by_pointer_field_auto_prefixes_storage_form
    stub_aggregate([{ "objectId" => "GroupArtist$alice", "value" => 4 }])
    result = @agent.execute(:group_by, class_name: "GroupSong", field: "artist")
    assert result[:success]
    group_stage = find_stage(@agg_calls.first[1], "$group")["$group"]
    assert_equal "$_p_artist", group_stage["_id"]
    body = result[:data]
    assert_equal "GroupArtist", body[:pointer_class]
    assert_equal [{ key: "alice", value: 4 }], body[:groups]
  end

  def test_group_by_sort_value_desc_emits_sort_stage_and_limit
    # The handler pushes sort + limit into the wire pipeline so the
    # database handles top-K, not Ruby. Stub contents are irrelevant
    # to this test — the load-bearing assertions are the emitted
    # pipeline shape (`$sort` direction and `$limit` cap+1) and that
    # the handler echoes the sort parameter on the response envelope.
    stub_aggregate([
      { "objectId" => "b", "value" => 10 },
      { "objectId" => "c", "value" => 5  },
      { "objectId" => "a", "value" => 2  },
    ])
    result = @agent.execute(:group_by, class_name: "GroupSong", field: "genre",
                            sort: "value_desc", limit: 200)
    assert result[:success]
    assert_equal "value_desc", result[:data][:sort]

    pipeline = @agg_calls.first[1]
    assert_equal({ "value" => -1 }, find_stage(pipeline, "$sort")["$sort"])
    # cap+1 so the handler can detect truncation server-side.
    assert_equal 201, find_stage(pipeline, "$limit")["$limit"]
  end

  def test_group_by_invalid_operation_raises_validation
    stub_aggregate([])
    result = @agent.execute(:group_by, class_name: "GroupSong", field: "genre",
                            operation: "bogus")
    refute result[:success]
    assert_equal :invalid_argument, result[:error_code]
  end

  def test_group_by_limit_caps_result_count
    rows = 5.times.map { |i| { "objectId" => "g#{i}", "value" => i } }
    stub_aggregate(rows)
    result = @agent.execute(:group_by, class_name: "GroupSong", field: "genre", limit: 2)
    assert result[:success]
    assert_equal 2, result[:data][:group_count]
    assert result[:data][:truncated]
  end

  # ---------------------------------------------------------------------
  # group_by_date — pipeline shape
  # ---------------------------------------------------------------------

  def test_group_by_date_day_interval
    stub_aggregate([
      { "objectId" => { "year" => 2024, "month" => 11, "day" => 24 }, "value" => 5 },
      { "objectId" => { "year" => 2024, "month" => 11, "day" => 25 }, "value" => 8 },
    ])
    result = @agent.execute(:group_by_date, class_name: "GroupSong",
                            field: "createdAt", interval: "day")
    assert result[:success], result.inspect
    body = result[:data]
    assert_equal "day", body[:interval]
    keys = body[:groups].map { |g| g[:key] }
    assert_equal ["2024-11-24", "2024-11-25"], keys

    _class, pipeline = @agg_calls.first
    group_id = find_stage(pipeline, "$group")["$group"]["_id"]
    assert_equal({ "$year"        => "$createdAt" }, group_id["year"])
    assert_equal({ "$month"       => "$createdAt" }, group_id["month"])
    assert_equal({ "$dayOfMonth"  => "$createdAt" }, group_id["day"])
  end

  def test_group_by_date_with_timezone
    stub_aggregate([{ "objectId" => { "year" => 2024, "month" => 11, "day" => 24 }, "value" => 1 }])
    result = @agent.execute(:group_by_date, class_name: "GroupSong",
                            field: "createdAt", interval: "day", timezone: "America/New_York")
    assert result[:success]
    group_id = find_stage(@agg_calls.first[1], "$group")["$group"]["_id"]
    expected = { "date" => "$createdAt", "timezone" => "America/New_York" }
    assert_equal({ "$year" => expected }, group_id["year"])
    assert_equal "America/New_York", result[:data][:timezone]
  end

  def test_group_by_date_month_format
    stub_aggregate([
      { "objectId" => { "year" => 2025, "month" => 1 }, "value" => 50 },
      { "objectId" => { "year" => 2024, "month" => 12 }, "value" => 30 },
    ])
    result = @agent.execute(:group_by_date, class_name: "GroupSong",
                            field: "createdAt", interval: "month")
    assert result[:success]
    keys = result[:data][:groups].map { |g| g[:key] }
    assert_equal ["2024-12", "2025-01"], keys, "should default to chronological order"
  end

  def test_group_by_date_invalid_interval
    stub_aggregate([])
    result = @agent.execute(:group_by_date, class_name: "GroupSong",
                            field: "createdAt", interval: "fortnight")
    refute result[:success]
    assert_equal :invalid_argument, result[:error_code]
  end

  def test_group_by_date_invalid_timezone
    stub_aggregate([])
    result = @agent.execute(:group_by_date, class_name: "GroupSong",
                            field: "createdAt", interval: "day",
                            timezone: "evil; DROP TABLE")
    refute result[:success]
    assert_equal :invalid_argument, result[:error_code]
  end

  def test_group_by_date_sort_value_desc_uses_wire_sort
    # Stub returns rows in the order $sort {value:-1} would produce.
    stub_aggregate([
      { "objectId" => { "year" => 2024, "month" => 11, "day" => 25 }, "value" => 9 },
      { "objectId" => { "year" => 2024, "month" => 11, "day" => 24 }, "value" => 3 },
      { "objectId" => { "year" => 2024, "month" => 11, "day" => 26 }, "value" => 1 },
    ])
    result = @agent.execute(:group_by_date, class_name: "GroupSong",
                            field: "createdAt", interval: "day", sort: "value_desc")
    keys = result[:data][:groups].map { |g| g[:key] }
    assert_equal ["2024-11-25", "2024-11-24", "2024-11-26"], keys
    pipeline = @agg_calls.first[1]
    assert_equal({ "value" => -1 }, find_stage(pipeline, "$sort")["$sort"])
  end

  # ---------------------------------------------------------------------
  # distinct — pipeline shape
  # ---------------------------------------------------------------------

  def test_distinct_returns_values_array
    stub_aggregate([
      { "objectId" => "rock" },
      { "objectId" => "jazz" },
      { "objectId" => "blues" },
    ])
    result = @agent.execute(:distinct, class_name: "GroupSong", field: "genre")
    assert result[:success]
    body = result[:data]
    assert_equal %w[rock jazz blues], body[:values]
    assert_equal 3, body[:count]

    _class, pipeline = @agg_calls.first
    assert_equal({ "$group" => { "_id" => "$genre" } }, find_stage(pipeline, "$group"))
  end

  def test_distinct_pointer_field_strips_class_prefix
    stub_aggregate([
      { "objectId" => "GroupArtist$alice" },
      { "objectId" => "GroupArtist$bob"   },
    ])
    result = @agent.execute(:distinct, class_name: "GroupSong", field: "artist")
    assert result[:success]
    body = result[:data]
    assert_equal "GroupArtist", body[:pointer_class]
    assert_equal %w[alice bob], body[:values]

    pipeline = @agg_calls.first[1]
    assert_equal "$_p_artist", find_stage(pipeline, "$group")["$group"]["_id"]
  end

  def test_distinct_sort_emits_wire_sort_stage
    # Distinct's asc/desc maps to wire-side $sort on _id; verify the
    # stage is emitted, then trust Mongo's sort (stub returns sorted).
    stub_aggregate([{ "objectId" => "a" }, { "objectId" => "b" }, { "objectId" => "c" }])
    asc = @agent.execute(:distinct, class_name: "GroupSong", field: "genre", sort: "asc")
    assert_equal %w[a b c], asc[:data][:values]
    assert_equal({ "_id" => 1 }, find_stage(@agg_calls.first[1], "$sort")["$sort"])

    @agg_calls.clear
    stub_aggregate([{ "objectId" => "c" }, { "objectId" => "b" }, { "objectId" => "a" }])
    desc = @agent.execute(:distinct, class_name: "GroupSong", field: "genre", sort: "desc")
    assert_equal %w[c b a], desc[:data][:values]
    assert_equal({ "_id" => -1 }, find_stage(@agg_calls.first[1], "$sort")["$sort"])
  end

  def test_distinct_invalid_sort
    stub_aggregate([])
    result = @agent.execute(:distinct, class_name: "GroupSong", field: "genre", sort: "weird")
    refute result[:success]
    assert_equal :invalid_argument, result[:error_code]
  end

  def test_distinct_limit_caps_values
    rows = 8.times.map { |i| { "objectId" => "v#{i}" } }
    stub_aggregate(rows)
    result = @agent.execute(:distinct, class_name: "GroupSong", field: "genre", limit: 3)
    assert result[:success]
    assert_equal 3, result[:data][:count]
    assert result[:data][:truncated]
  end

  # ---------------------------------------------------------------------
  # Security gates
  # ---------------------------------------------------------------------

  def test_group_by_invalid_field_identifier
    stub_aggregate([])
    result = @agent.execute(:group_by, class_name: "GroupSong", field: "evil; drop")
    refute result[:success]
    assert_equal :invalid_argument, result[:error_code]
  end

  # ---------------------------------------------------------------------
  # dry_run mode — returns the constructed pipeline without executing
  # ---------------------------------------------------------------------

  def test_group_by_dry_run_returns_pipeline_without_executing
    stub_aggregate([])  # would fail loudly if called
    result = @agent.execute(:group_by, class_name: "GroupSong", field: "genre",
                            operation: "sum", value_field: "plays",
                            sort: "value_desc", limit: 50, dry_run: true)
    assert result[:success]
    body = result[:data]
    assert_equal true, body[:dry_run]
    assert_equal "GroupSong", body[:class_name]
    assert body[:pipeline].is_a?(Array)
    assert_empty @agg_calls, "dry_run must not execute the pipeline"

    group_stage = find_stage(body[:pipeline], "$group")
    assert_equal "$genre", group_stage["$group"]["_id"]
    assert_equal({ "$sum" => "$plays" }, group_stage["$group"]["value"])

    sort_stage = find_stage(body[:pipeline], "$sort")
    assert_equal({ "value" => -1 }, sort_stage["$sort"])

    limit_stage = find_stage(body[:pipeline], "$limit")
    assert_equal 51, limit_stage["$limit"]

    assert_equal "sum", body[:parameters][:operation]
    assert_match(/dry_run mode/, body[:hint])
  end

  def test_group_by_date_dry_run_returns_pipeline
    stub_aggregate([])
    result = @agent.execute(:group_by_date, class_name: "GroupSong",
                            field: "createdAt", interval: "month",
                            timezone: "America/New_York", dry_run: true)
    assert result[:success]
    body = result[:data]
    assert body[:dry_run]
    assert_empty @agg_calls
    group_id = find_stage(body[:pipeline], "$group")["$group"]["_id"]
    assert_equal({ "date" => "$createdAt", "timezone" => "America/New_York" }, group_id["year"]["$year"])
    assert_equal "month", body[:parameters][:interval]
  end

  def test_distinct_dry_run_returns_pipeline
    stub_aggregate([])
    result = @agent.execute(:distinct, class_name: "GroupSong", field: "genre",
                            sort: "asc", dry_run: true)
    assert result[:success]
    body = result[:data]
    assert body[:dry_run]
    assert_empty @agg_calls
    assert_equal({ "$group" => { "_id" => "$genre" } }, find_stage(body[:pipeline], "$group"))
    assert_equal({ "_id" => 1 }, find_stage(body[:pipeline], "$sort")["$sort"])
  end

  def test_dry_run_still_validates_inputs
    stub_aggregate([])
    # Invalid field shape must still be refused with dry_run set —
    # dry_run is not an authorization bypass.
    result = @agent.execute(:group_by, class_name: "GroupSong", field: "evil;drop",
                            dry_run: true)
    refute result[:success]
    assert_equal :invalid_argument, result[:error_code]
  end

  def test_dry_run_respects_agent_hidden_class
    stub_aggregate([])
    result = @agent.execute(:group_by, class_name: "GroupHiddenSong", field: "genre",
                            dry_run: true)
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
  end

  def test_group_by_refuses_agent_hidden_class
    stub_aggregate([])
    result = @agent.execute(:group_by, class_name: "GroupHiddenSong", field: "genre")
    refute result[:success], "hidden class must be refused"
    assert_equal :access_denied, result[:error_code]
  end

  def test_group_by_collscan_preflight_refuses_when_unindexed
    # Wire a fake client that returns both a COLLSCAN explain plan and
    # a normal aggregate response. With refuse_collscan = true, the
    # handler must refuse before invoking aggregate_pipeline.
    Parse::Agent.refuse_collscan = true
    fake = Object.new
    agg_called = false
    fake.define_singleton_method(:find_objects) do |_class, _query, **_opts|
      r = Object.new
      r.define_singleton_method(:success?) { true }
      r.define_singleton_method(:result)   {
        { "queryPlanner" => { "winningPlan" => { "stage" => "COLLSCAN" } } }
      }
      r
    end
    fake.define_singleton_method(:aggregate_pipeline) do |_class, _pipeline, **_opts|
      agg_called = true
      raise "aggregate should not have been called after COLLSCAN refusal"
    end
    @agent.define_singleton_method(:client) { fake }

    result = @agent.execute(:group_by, class_name: "GroupSong", field: "genre",
                            where: { "title" => "Strict" })
    # Refusal envelope comes back as data (the handler returns it directly).
    assert result[:success], result.inspect
    assert result[:data][:refused]
    refute agg_called, "aggregate must not run when COLLSCAN preflight refuses"
  end

  # ---------------------------------------------------------------------
  # H-4 field_map translation tests
  # ---------------------------------------------------------------------

  # group_by with a snake_case pointer field must emit _p_<camelCase> not _p_<snake_case>.
  # GroupTrack.belongs_to :author_id maps key :author_id → wire name :authorId.
  # The pipeline _id must be "$_p_authorId", not "$_p_author_id".
  def test_group_by_resolves_snake_case_pointer_via_field_map
    stub_aggregate([{ "objectId" => "GroupAuthor$alice", "value" => 4 }])
    result = @agent.execute(:group_by, class_name: "GroupTrack", field: "author_id")
    assert result[:success], result.inspect
    group_stage = find_stage(@agg_calls.first[1], "$group")["$group"]
    assert_equal "$_p_authorId", group_stage["_id"],
                 "pointer field must use camelCase wire name from field_map"
  end

  # distinct with a snake_case pointer field must emit _p_<camelCase>.
  def test_distinct_resolves_snake_case_pointer_via_field_map
    stub_aggregate([{ "objectId" => "GroupAuthor$alice" }, { "objectId" => "GroupAuthor$bob" }])
    result = @agent.execute(:distinct, class_name: "GroupTrack", field: "author_id")
    assert result[:success], result.inspect
    group_stage = find_stage(@agg_calls.first[1], "$group")["$group"]
    assert_equal "$_p_authorId", group_stage["_id"],
                 "distinct pointer field must use camelCase wire name from field_map"
  end

  # value_field with a snake_case non-pointer property must use the camelCase wire name.
  # play_count → playCount; the accumulator must be {"$sum"=>"$playCount"}.
  def test_group_by_value_field_resolves_snake_case
    stub_aggregate([{ "objectId" => "GroupAuthor$alice", "value" => 100 }])
    result = @agent.execute(:group_by, class_name: "GroupTrack", field: "author_id",
                            operation: "sum", value_field: "play_count")
    assert result[:success], result.inspect
    group_stage = find_stage(@agg_calls.first[1], "$group")["$group"]
    assert_equal({ "$sum" => "$playCount" }, group_stage["value"],
                 "value_field must resolve snake_case to camelCase wire name")
  end

  # group_by_date with a snake_case date field must use the camelCase wire name.
  # released_at → releasedAt; the date expression must reference "$releasedAt".
  def test_group_by_date_resolves_snake_case_date_via_field_map
    stub_aggregate([{ "objectId" => { "year" => 2024, "month" => 6, "day" => 1 }, "value" => 3 }])
    result = @agent.execute(:group_by_date, class_name: "GroupTrack",
                            field: "released_at", interval: "day")
    assert result[:success], result.inspect
    group_id = find_stage(@agg_calls.first[1], "$group")["$group"]["_id"]
    # The date expression for "day" interval contains year/month/day sub-expressions.
    # Each sub-expression must reference "$releasedAt", not "$released_at".
    assert_equal({ "$year" => "$releasedAt" }, group_id["year"],
                 "group_by_date must resolve snake_case date field via field_map")
  end

  # group_by_date must reject pointer fields with a ValidationError rather than
  # silently emitting a pipeline that null-buckets every document.
  def test_group_by_date_rejects_pointer_field
    stub_aggregate([])
    result = @agent.execute(:group_by_date, class_name: "GroupTrack",
                            field: "author_id", interval: "day")
    refute result[:success], "pointer field must be rejected by group_by_date"
    assert_equal :invalid_argument, result[:error_code],
                 "expected invalid_argument error code for pointer field"
  end

  # group_by_date must reject :array fields (e.g., tags) for the same reason.
  def test_group_by_date_rejects_array_field
    stub_aggregate([])
    result = @agent.execute(:group_by_date, class_name: "GroupTrack",
                            field: "tags", interval: "day")
    refute result[:success], "array field must be rejected by group_by_date"
    assert_equal :invalid_argument, result[:error_code],
                 "expected invalid_argument error code for array field"
  end

  # group_by_date must reject :relation fields for the same reason.
  # GroupRelationSong is defined as a named fixture class above.
  def test_group_by_date_rejects_relation_field
    stub_aggregate([])
    result = @agent.execute(:group_by_date, class_name: "GroupRelationSong",
                            field: "collaborators", interval: "day")
    refute result[:success], "relation field must be rejected by group_by_date"
    assert_equal :invalid_argument, result[:error_code],
                 "expected invalid_argument error code for relation field"
  end
end
