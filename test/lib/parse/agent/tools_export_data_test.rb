# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "csv"

# ============================================================================
# Tests for the export_data tool — CSV / Markdown / fixed-width text export
# of Parse data, with column aliasing and access-control gates inherited
# from query_class / aggregate.
# ============================================================================
class ToolsExportDataTest < Minitest::Test
  class ExportTestStudent < Parse::Object
    parse_class "ExportTestStudent"
    property :name, :string
    property :grade, :integer
    property :ssn, :string
  end

  class ExportTestSubject < Parse::Object
    parse_class "ExportTestSubject"
    property :name, :string
  end

  class ExportRestrictedStudent < Parse::Object
    parse_class "ExportRestrictedStudent"
    property :name, :string
    property :ssn, :string
    agent_fields :name
  end

  class ExportHidden < Parse::Object
    parse_class "ExportHidden"
    property :secret, :string
    agent_hidden
  end

  ROWS = [
    { "objectId" => "a1", "name" => "Ada",   "grade" => 11,
      "subject" => { "__type" => "Object", "className" => "ExportTestSubject", "name" => "Algebra II" } },
    { "objectId" => "a2", "name" => "Bao",   "grade" => 10,
      "subject" => { "__type" => "Object", "className" => "ExportTestSubject", "name" => "Biology" } },
    { "objectId" => "a3", "name" => "Cheng", "grade" => 12,
      "subject" => { "__type" => "Object", "className" => "ExportTestSubject", "name" => "Algebra II" } },
  ].freeze

  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test", api_key: "test")
    end
    @agent = Parse::Agent.new(permissions: :readonly)
    rows = ROWS
    @find_calls   = []
    @agg_calls    = []
    fake_client   = Object.new
    find_calls    = @find_calls
    agg_calls     = @agg_calls
    fake_client.define_singleton_method(:find_objects) do |class_name, query, **_opts|
      find_calls << [class_name, query]
      r = Object.new
      r.define_singleton_method(:success?) { true }
      r.define_singleton_method(:results) { rows }
      r
    end
    fake_client.define_singleton_method(:aggregate_pipeline) do |class_name, pipeline, **_opts|
      agg_calls << [class_name, pipeline]
      r = Object.new
      r.define_singleton_method(:success?) { true }
      r.define_singleton_method(:results) { rows }
      r
    end
    @agent.define_singleton_method(:client) { fake_client }
  end

  # ---- Format coverage ----------------------------------------------------

  def test_csv_default_format
    result = @agent.execute(:export_data, class_name: "ExportTestStudent", limit: 10)
    assert result[:success]
    out = result[:data][:output]
    parsed = CSV.parse(out, headers: true)
    assert_equal 3, parsed.count
    assert_includes parsed.headers, "name"
    assert_equal "Ada", parsed[0]["name"]
    assert_equal "csv", result[:data][:format]
  end

  def test_markdown_format
    result = @agent.execute(:export_data, class_name: "ExportTestStudent",
                            limit: 10, format: "markdown")
    assert result[:success]
    out = result[:data][:output]
    assert_match(/\A\| .+\|\n\| --- \|/, out, "must start with header row + separator")
    assert_includes out, "Ada"
    assert_includes out, "Cheng"
  end

  def test_text_table_format
    result = @agent.execute(:export_data, class_name: "ExportTestStudent",
                            limit: 10, format: "table")
    assert result[:success]
    out = result[:data][:output]
    assert_match(/\A\+-/, out, "must start with corner +")
    assert_match(/\+\z/, out, "must end with corner +")
    assert_includes out, "| Ada"
    # Headers padded with column widths
    assert_match(/\| name\s+ \|/, out)
  end

  def test_invalid_format_rejected
    result = @agent.execute(:export_data, class_name: "ExportTestStudent", format: "yaml")
    refute result[:success]
    assert_equal :invalid_argument, result[:error_code]
  end

  # ---- Column aliasing ---------------------------------------------------

  def test_columns_with_string_specs
    result = @agent.execute(:export_data, class_name: "ExportTestStudent",
                            columns: ["name", "grade"], format: "csv")
    parsed = CSV.parse(result[:data][:output], headers: true)
    assert_equal %w[name grade], parsed.headers
  end

  def test_columns_with_hash_aliases
    result = @agent.execute(:export_data, class_name: "ExportTestStudent",
                            columns: ["name", { "grade" => "Year" }],
                            format: "csv")
    parsed = CSV.parse(result[:data][:output], headers: true)
    assert_equal %w[name Year], parsed.headers
    # Value is mapped from `grade`, displayed under the `Year` header
    assert_equal "11", parsed[0]["Year"]
  end

  def test_columns_dotted_path_extraction
    result = @agent.execute(:export_data, class_name: "ExportTestStudent",
                            columns: ["name", { "subject.name" => "Subject" }],
                            include: ["subject"], format: "csv")
    parsed = CSV.parse(result[:data][:output], headers: true)
    assert_equal "Algebra II", parsed[0]["Subject"]
    assert_equal "Biology",    parsed[1]["Subject"]
  end

  def test_columns_invalid_hash_rejected
    result = @agent.execute(:export_data, class_name: "ExportTestStudent",
                            columns: [{ "a" => "A", "b" => "B" }])
    refute result[:success]
    assert_equal :invalid_argument, result[:error_code]
  end

  def test_columns_invalid_type_rejected
    result = @agent.execute(:export_data, class_name: "ExportTestStudent",
                            columns: [123])
    refute result[:success]
    assert_equal :invalid_argument, result[:error_code]
  end

  # ---- Mode selection ----------------------------------------------------

  def test_query_mode_calls_find_objects
    @agent.execute(:export_data, class_name: "ExportTestStudent", limit: 10)
    assert_equal 1, @find_calls.size
    assert_empty @agg_calls
  end

  def test_aggregate_mode_calls_aggregate_pipeline
    @agent.execute(:export_data, class_name: "ExportTestStudent",
                   pipeline: [{ "$match" => { "name" => "Ada" } }])
    assert_equal 1, @agg_calls.size
    assert_empty @find_calls
  end

  # ---- Access-control inheritance ---------------------------------------

  def test_export_against_hidden_class_is_denied
    result = @agent.execute(:export_data, class_name: "ExportHidden")
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
  end

  def test_export_aggregate_lookup_into_hidden_is_denied
    result = @agent.execute(:export_data, class_name: "ExportTestStudent",
                            pipeline: [{ "$lookup" => { "from" => "ExportHidden",
                                                        "as" => "x", "localField" => "_id",
                                                        "foreignField" => "_id" } }])
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
  end

  def test_export_intersects_keys_with_agent_fields_allowlist
    @agent.execute(:export_data, class_name: "ExportRestrictedStudent",
                   keys: ["ssn", "name"])
    # The keys param should be filtered to drop ssn since it's not in allowlist
    query = @find_calls.last.last
    keys = query[:keys].split(",")
    refute_includes keys, "ssn"
    assert_includes keys, "name"
  end

  # ---- Inferred headers when columns omitted ----------------------------

  def test_inferred_headers_exclude_internal_fields
    rows_with_internals = [{ "objectId" => "x", "name" => "Ada",
                             "__type" => "Object", "className" => "Foo",
                             "ACL" => {} }]
    headers = Parse::Agent::Tools.infer_export_columns_from(rows_with_internals.first).map { |c| c[:header] }
    refute_includes headers, "__type"
    refute_includes headers, "className"
    refute_includes headers, "ACL"
    assert_includes headers, "name"
  end

  # ---- Edge cases -------------------------------------------------------

  def test_empty_result_set
    # Override find_objects to return empty
    @agent.client.define_singleton_method(:find_objects) do |_class, _q, **_opts|
      r = Object.new
      r.define_singleton_method(:success?) { true }
      r.define_singleton_method(:results) { [] }
      r
    end
    result = @agent.execute(:export_data, class_name: "ExportTestStudent",
                            columns: ["name"], format: "csv")
    assert result[:success]
    assert_equal 0, result[:data][:row_count]
    # CSV.generate with just the header row produces "name\n"
    assert_includes result[:data][:output], "name"
  end

  def test_value_stringification_for_complex_types
    # A nested hash that doesn't get extracted via dotted path should serialize as JSON
    rows_with_array = [{ "objectId" => "x", "tags" => %w[red green blue] }]
    out = Parse::Agent::Tools.stringify_export_value(rows_with_array.first["tags"])
    assert_equal '["red","green","blue"]', out
  end
end
