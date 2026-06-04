# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/agent"

# Coverage for did-you-mean class-name suggestions on the get_schema
# fetch-failure path (B5b). A mistyped class name should raise a
# ValidationError (so the hint reaches the wire) carrying near matches.
class ClassNameSuggestionTest < Minitest::Test
  T = Parse::Agent::Tools

  class SuggDocPost < Parse::Object
    parse_class "SuggDocPost"
  end

  class SuggDocWorkspace < Parse::Object
    parse_class "SuggDocWorkspace"
  end

  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test-app-id", api_key: "test-api-key")
    end
    @agent = Parse::Agent.new(permissions: :readonly)
    Parse::Agent.suppress_master_key_warning = true
  end

  def teardown
    Parse::Agent.suppress_master_key_warning = false
  end

  def test_edit_distance_basics
    assert_equal 0, T.name_edit_distance("post", "post")
    assert_equal 1, T.name_edit_distance("pst", "post")
    assert_equal 4, T.name_edit_distance("", "post")
  end

  def test_suggests_near_match
    assert_includes T.suggest_class_names("SuggDocPst"), "SuggDocPost"
  end

  def test_does_not_suggest_unrelated_names
    assert_empty T.suggest_class_names("ZZZZZZZZZZ")
  end

  def test_get_schema_failure_raises_validation_error_with_suggestion
    fake_response = Object.new
    def fake_response.success?; false; end
    fake_client = Object.new
    fake_client.define_singleton_method(:schema) { |_cn| fake_response }

    @agent.stub(:client, fake_client) do
      err = assert_raises(Parse::Agent::ValidationError) do
        T.get_schema(@agent, class_name: "SuggDocPst")
      end
      assert_match(/Could not fetch schema/, err.message)
      assert_match(/Did you mean.*SuggDocPost/, err.message)
    end
  end
end
