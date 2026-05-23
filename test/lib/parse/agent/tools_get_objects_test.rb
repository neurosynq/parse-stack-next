# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/agent"

class ToolsGetObjectsTest < Minitest::Test
  T = Parse::Agent::Tools

  def setup
    Parse::Agent::Tools.reset_registry!
    unless Parse::Client.client?
      Parse.setup(
        server_url: "http://localhost:1337/parse",
        application_id: "test-app-id",
        api_key: "test-api-key",
      )
    end
    @agent = Parse::Agent.new(permissions: :readonly)
  end

  def teardown
    Parse::Agent::Tools.reset_registry!
  end

  # ---------------------------------------------------------------------------
  # Helper: stub agent.client.find_objects to return a fake response
  # ---------------------------------------------------------------------------

  def stub_find_objects(results: [], success: true)
    fake_response = Minitest::Mock.new
    fake_response.expect(:success?, success)
    if success
      fake_response.expect(:results, results)
    else
      fake_response.expect(:error, "stubbed error")
    end
    fake_response
  end

  # ---------------------------------------------------------------------------
  # Empty ids
  # ---------------------------------------------------------------------------

  def test_empty_ids_returns_empty_result_without_querying
    result = T.get_objects(@agent, class_name: "Song", ids: [])
    assert_equal "Song",  result[:class_name]
    assert_equal({},       result[:objects])
    assert_equal([],       result[:missing])
    assert_equal 0,        result[:requested]
    assert_equal 0,        result[:found]
  end

  # ---------------------------------------------------------------------------
  # Successful batch fetch
  # ---------------------------------------------------------------------------

  def test_50_ids_success
    ids = (1..50).map { |i| "id#{i.to_s.rjust(8, "0")}"[0, 10] }
    ids = ids.map.with_index { |_, i| "abcde#{i.to_s.rjust(5, "0")}"[0, 10] }
    # Ensure uniqueness and valid format
    ids = (1..50).map { |i| format("abc%07d", i) }

    returned_objects = ids.map { |id| { "objectId" => id, "name" => "track #{id}" } }

    fake_response = Minitest::Mock.new
    fake_response.expect(:success?, true)
    fake_response.expect(:results, returned_objects)

    @agent.client.stub(:find_objects, fake_response) do
      result = T.get_objects(@agent, class_name: "Song", ids: ids)
      assert_equal 50, result[:requested]
      assert_equal 50, result[:found]
      assert_equal 0,  result[:missing].size
    end
  end

  # ---------------------------------------------------------------------------
  # 51 ids after dedup raises ValidationError
  # ---------------------------------------------------------------------------

  def test_51_unique_ids_raises_validation_error
    ids = (1..51).map { |i| format("abc%07d", i) }
    assert_raises(Parse::Agent::ValidationError) do
      T.get_objects(@agent, class_name: "Song", ids: ids)
    end
  end

  # ---------------------------------------------------------------------------
  # Duplicate ids are deduped before limit check
  # ---------------------------------------------------------------------------

  def test_duplicate_ids_deduped_before_limit_check
    # 51 entries but only 25 unique — should NOT raise
    ids = Array.new(51) { |i| format("abc%07d", i % 25) }

    returned_objects = (0..24).map { |i| { "objectId" => format("abc%07d", i) } }
    fake_response = Minitest::Mock.new
    fake_response.expect(:success?, true)
    fake_response.expect(:results, returned_objects)

    @agent.client.stub(:find_objects, fake_response) do
      result = T.get_objects(@agent, class_name: "Song", ids: ids)
      assert_equal 25, result[:requested]
    end
  end

  # ---------------------------------------------------------------------------
  # Invalid class_name raises ValidationError
  # ---------------------------------------------------------------------------

  def test_invalid_class_name_raises_validation_error
    assert_raises(Parse::Agent::ValidationError) do
      T.get_objects(@agent, class_name: "bad class!", ids: ["abc1234567"])
    end
  end

  def test_class_name_starting_with_digit_raises_validation_error
    assert_raises(Parse::Agent::ValidationError) do
      T.get_objects(@agent, class_name: "1Song", ids: ["abc1234567"])
    end
  end

  # ---------------------------------------------------------------------------
  # Invalid id format raises ValidationError
  # ---------------------------------------------------------------------------

  def test_invalid_id_format_raises_validation_error
    assert_raises(Parse::Agent::ValidationError) do
      T.get_objects(@agent, class_name: "Song", ids: ["has spaces!"])
    end
  end

  def test_id_too_long_raises_validation_error
    long_id = "a" * 33
    assert_raises(Parse::Agent::ValidationError) do
      T.get_objects(@agent, class_name: "Song", ids: [long_id])
    end
  end

  # ---------------------------------------------------------------------------
  # nil ids raises ValidationError
  # ---------------------------------------------------------------------------

  def test_nil_ids_raises_validation_error
    assert_raises(Parse::Agent::ValidationError) do
      T.get_objects(@agent, class_name: "Song", ids: nil)
    end
  end

  # ---------------------------------------------------------------------------
  # agent_fields allowlist applied as keys projection
  # ---------------------------------------------------------------------------

  def test_agent_fields_allowlist_applied_to_query
    klass_name = "ToolGetObjectsAllowlistTest"
    captured_query = nil

    # Patch MetadataRegistry.field_allowlist to return a known allowlist
    original_method = Parse::Agent::MetadataRegistry.method(:field_allowlist)
    Parse::Agent::MetadataRegistry.define_singleton_method(:field_allowlist) do |cn|
      cn == klass_name ? %w[title plays objectId createdAt updatedAt] : original_method.call(cn)
    end

    begin
      returned_objects = [{ "objectId" => "abc1234567", "title" => "Song A" }]
      fake_response = Minitest::Mock.new
      fake_response.expect(:success?, true)
      fake_response.expect(:results, returned_objects)

      @agent.client.stub(:find_objects, ->(cn, query, **opts) {
        captured_query = query
        fake_response
      }) do
        T.get_objects(@agent, class_name: klass_name, ids: ["abc1234567"])
      end
    ensure
      Parse::Agent::MetadataRegistry.define_singleton_method(:field_allowlist, &original_method)
    end

    refute_nil captured_query, "find_objects should have been called"
    # field_allowlist already includes ALWAYS_KEEP_FIELDS in our stub above
    keys_projection = captured_query[:keys].split(",")
    assert_includes keys_projection, "title"
    assert_includes keys_projection, "plays"
    assert_includes keys_projection, "objectId"
  end

  # ---------------------------------------------------------------------------
  # missing array correctly populated
  # ---------------------------------------------------------------------------

  def test_missing_array_populated_for_absent_ids
    requested_ids = %w[abc1234567 def1234567 ghi1234567]
    # Only return 2 of the 3
    returned_objects = [
      { "objectId" => "abc1234567" },
      { "objectId" => "ghi1234567" },
    ]

    fake_response = Minitest::Mock.new
    fake_response.expect(:success?, true)
    fake_response.expect(:results, returned_objects)

    @agent.client.stub(:find_objects, fake_response) do
      result = T.get_objects(@agent, class_name: "Song", ids: requested_ids)
      assert_equal 3, result[:requested]
      assert_equal 2, result[:found]
      assert_equal ["def1234567"], result[:missing]
    end
  end

  def test_all_ids_missing_returns_full_missing_array
    ids = %w[abc1234567 def1234567]

    fake_response = Minitest::Mock.new
    fake_response.expect(:success?, true)
    fake_response.expect(:results, [])

    @agent.client.stub(:find_objects, fake_response) do
      result = T.get_objects(@agent, class_name: "Song", ids: ids)
      assert_equal 2, result[:requested]
      assert_equal 0, result[:found]
      assert_equal ids.sort, result[:missing].sort
    end
  end

  # ---------------------------------------------------------------------------
  # validate_include! — get_objects include parameter validation
  # ---------------------------------------------------------------------------

  def test_include_nil_does_not_raise
    # nil means "no include requested" — should succeed without querying
    # Use empty ids to bypass the fetch entirely
    result = T.get_objects(@agent, class_name: "Song", ids: [], include: nil)
    assert_equal({}, result[:objects])
  end

  def test_include_valid_dotted_path_passes_validation
    ids = %w[abc1234567]
    returned_objects = [{ "objectId" => "abc1234567" }]
    fake_response = Minitest::Mock.new
    fake_response.expect(:success?, true)
    fake_response.expect(:results, returned_objects)

    @agent.client.stub(:find_objects, fake_response) do
      result = T.get_objects(@agent, class_name: "Song", ids: ids, include: ["author.team", "owner"])
      assert_equal 1, result[:found]
    end
  end

  def test_include_entry_too_long_raises_validation_error
    assert_raises(Parse::Agent::ValidationError) do
      T.get_objects(@agent, class_name: "Song", ids: ["abc1234567"], include: ["a" * 200])
    end
  end

  def test_include_array_exceeds_limit_raises_validation_error
    assert_raises(Parse::Agent::ValidationError) do
      T.get_objects(@agent, class_name: "Song", ids: ["abc1234567"], include: Array.new(25) { "foo" })
    end
  end

  def test_include_underscore_prefix_raises_validation_error
    assert_raises(Parse::Agent::ValidationError) do
      T.get_objects(@agent, class_name: "Song", ids: ["abc1234567"], include: ["_session_token"])
    end
  end

  def test_include_not_array_raises_validation_error
    assert_raises(Parse::Agent::ValidationError) do
      T.get_objects(@agent, class_name: "Song", ids: ["abc1234567"], include: "author")
    end
  end

  # ---------------------------------------------------------------------------
  # get_objects is in PERMISSION_LEVELS[:readonly]
  # ---------------------------------------------------------------------------

  def test_get_objects_allowed_for_readonly_agent
    assert @agent.tool_allowed?(:get_objects)
  end

  def test_get_objects_in_tool_definitions
    defs = @agent.tool_definitions(format: :openai)
    names = defs.map { |d| d[:function][:name] }
    assert_includes names, "get_objects"
  end
end
