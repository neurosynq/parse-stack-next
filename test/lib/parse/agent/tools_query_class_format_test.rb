# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Tests for the format: kwarg on query_class. Lets the conversational
# read path produce CSV / Markdown / fixed-width-table dumps without
# round-tripping through export_data. Default is "json", which preserves
# the current structured-envelope behavior.
class ToolsQueryClassFormatTest < Minitest::Test
  T = Parse::Agent::Tools

  class FakeQueryClient
    def initialize(rows)
      @rows = rows
    end

    def find_objects(_class, _query, **_opts)
      rows = @rows
      response = Object.new
      response.define_singleton_method(:success?) { true }
      response.define_singleton_method(:results)  { rows }
      response.define_singleton_method(:count)    { rows.size }
      response.define_singleton_method(:error)    { nil }
      response
    end
  end

  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "t", api_key: "t")
    end
  end

  def build_agent(rows)
    agent = Parse::Agent.new
    agent.instance_variable_set(:@client, FakeQueryClient.new(rows))
    agent
  end

  ROWS = [
    { "objectId" => "abc", "name" => "Alice", "score" => 10 },
    { "objectId" => "def", "name" => "Bob",   "score" => 20 },
  ].freeze

  # ---- format: nil (default) -- existing structured envelope ------------

  def test_default_format_returns_structured_envelope
    agent = build_agent(ROWS)
    result = T.query_class(agent, class_name: "Test")
    # Original envelope shape: class_name + results + pagination etc.
    assert result.key?(:results), "default format should return the row envelope"
    assert_equal 2, result[:results].size
    assert_equal "Alice", result[:results][0]["name"]
  end

  def test_explicit_json_format_matches_default
    agent = build_agent(ROWS)
    result = T.query_class(agent, class_name: "Test", format: "json")
    assert result.key?(:results)
  end

  # ---- format: csv ------------------------------------------------------

  def test_csv_format_returns_text_envelope_with_headers_and_output
    agent = build_agent(ROWS)
    result = T.query_class(agent, class_name: "Test", format: "csv")
    assert_equal "csv", result[:format]
    assert_kind_of Array, result[:headers]
    assert_includes result[:headers], "name"
    assert_includes result[:headers], "score"
    assert_equal 2, result[:row_count]
    assert result[:output].lines.size >= 3, "csv output should have header + 2 data rows"
    assert_match(/Alice/, result[:output])
    assert_match(/Bob/,   result[:output])
  end

  # ---- format: markdown -------------------------------------------------

  def test_markdown_format_emits_pipe_table
    agent = build_agent(ROWS)
    result = T.query_class(agent, class_name: "Test", format: "markdown")
    assert_equal "markdown", result[:format]
    # First row of the output is the header row carrying every inferred column.
    assert_match(/^\| objectId \| name \| score \|/, result[:output])
    assert_match(/\| --- \| --- \| --- \|/, result[:output])
  end

  # ---- format: table ----------------------------------------------------

  def test_table_format_emits_fixed_width_table
    agent = build_agent(ROWS)
    result = T.query_class(agent, class_name: "Test", format: "table")
    assert_equal "table", result[:format]
    assert_match(/\+\-+/, result[:output])
    assert_match(/Alice/,  result[:output])
  end

  # ---- format: <invalid> -----------------------------------------------

  def test_unknown_format_raises_validation_error
    agent = build_agent(ROWS)
    err = assert_raises(Parse::Agent::ValidationError) do
      T.query_class(agent, class_name: "Test", format: "yaml")
    end
    assert_match(/format:/, err.message)
    assert_match(/json|csv|markdown|table/, err.message)
  end

  # ---- Empty result set -----------------------------------------------

  def test_csv_format_on_empty_result_returns_zero_rows
    agent = build_agent([])
    result = T.query_class(agent, class_name: "Test", format: "csv")
    assert_equal 0, result[:row_count]
    assert_equal [], result[:headers]
  end
end
