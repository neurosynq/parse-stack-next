# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/agent"
require "parse/agent/mcp_subscriptions"
require "csv"

# Opt-in server field names (5.8): `Parse::Agent.new(field_names: :server)`
# and `Aggregation#results(field_names: :server)` return data fields in the
# exact names Parse returns or the model declares, with no snake_case
# conversion. Omitting the option keeps every API's existing output. Naming
# is presentation only; access restrictions are identical in either mode.
class FieldNamesModeTest < Minitest::Test
  class FNSong < Parse::Object
    parse_class "FieldNamesSong"
    property :title, :string
    property :total_plays, :integer
    property :is_public, :boolean
    property :external_id, :string, field: :ExternalID
    property :meta, :object
    property :secret_note, :string
    belongs_to :artist, as: :user
    agent_fields :title, :total_plays, :is_public, :external_id, :meta, :artist
  end

  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse", application_id: "test",
                  api_key: "test", master_key: "test-master")
    end
  end

  ROW = {
    "_id" => "Rock", "objectId" => "o1", "createdAt" => "2026-10-06T00:00:00.000Z",
    "totalPlays" => 500, "total_plays" => 7, "ExternalID" => "EXT-9",
    "isPublic" => false, "missing" => nil,
    "nested" => { "innerKey" => { "deep_key" => [1, { "aB" => false }] } },
  }.freeze

  # ---- AggregationResult -----------------------------------------------

  def test_default_mode_is_unchanged
    r = Parse::AggregationResult.new({ "_id" => "Rock", "totalPlays" => 500 })
    assert_equal :default, r.field_names
    assert_equal({ _id: "Rock", total_plays: 500 }, r.to_h)
    assert_equal %i[_id total_plays], r.keys
    assert_equal 500, r["totalPlays"]
    assert_equal 500, r[:total_plays]
    assert_equal 500, r.total_plays
  end

  def test_server_mode_keeps_exact_names_values_and_nesting
    r = Parse::AggregationResult.new(ROW, field_names: :server)
    h = r.to_h
    assert_equal ROW.keys, h.keys, "every key survives verbatim, including colliding snake_case forms"
    assert(h.keys.all? { |k| k.is_a?(String) })
    assert_equal 500, h["totalPlays"]
    assert_equal 7, h["total_plays"], "a distinct snake_case key is not overwritten"
    assert_equal "EXT-9", h["ExternalID"]
    assert_equal false, h["isPublic"]
    assert h.key?("missing")
    assert_nil h["missing"]
    assert_equal ROW["nested"], h["nested"]
    assert_equal ROW.keys, r.keys
  end

  def test_server_mode_method_access_and_ambiguity
    r = Parse::AggregationResult.new(ROW, field_names: :server)
    assert_equal "EXT-9", r.ExternalID
    assert_equal false, r.is_public, "a snake_case name matching one key resolves"
    assert r.respond_to?(:is_public)
    assert_equal 7, r.total_plays, "an exact key wins over a snake_case match"
    ambiguous = Parse::AggregationResult.new({ "totalPlays" => 1, "TotalPlays" => 2 }, field_names: :server)
    err = assert_raises(ArgumentError) { ambiguous.total_plays }
    assert_match(/totalPlays/, err.message)
    assert_match(/TotalPlays/, err.message)
    assert_equal 2, ambiguous["TotalPlays"], "exact keys always resolve, even when a snake_case name is ambiguous"
  end

  def test_unsupported_modes_are_rejected
    assert_raises(ArgumentError) { Parse::AggregationResult.new({}, field_names: :camel) }
    assert_raises(ArgumentError) { Parse::Agent.new(field_names: :raw) }
    agg = Parse::Aggregation.new(FNSong.query, [{ "$group" => { "_id" => "$title" } }])
    assert_raises(ArgumentError) { agg.results(field_names: "snake") }
  end

  FakeResponse = Struct.new(:result) do
    def error? = false
  end

  def test_aggregation_results_materialize_in_the_requested_mode
    agg = Parse::Aggregation.new(FNSong.query, [{ "$group" => { "_id" => "$title" } }])
    rows = [{ "_id" => "Rock", "totalPlays" => 5, "ExternalID" => "E1" }]
    agg.define_singleton_method(:execute!) { FakeResponse.new(rows) }
    server = agg.results(field_names: :server).first
    assert_equal({ "_id" => "Rock", "totalPlays" => 5, "ExternalID" => "E1" }, server.to_h)
    default = agg.results.first
    assert_equal({ _id: "Rock", total_plays: 5, external_id: "E1" }, default.to_h)
  end

  # ---- agent naming mode -------------------------------------------------

  def test_agent_mode_defaults_validates_and_inherits
    assert_equal :default, Parse::Agent.new.field_names_mode
    parent = Parse::Agent.new(field_names: :server, fields: { FNSong => %i[title] })
    child = Parse::Agent.new(parent: parent)
    assert_equal :server, child.field_names_mode, "sub-agents inherit the naming mode"
    override = Parse::Agent.new(parent: parent, field_names: :default)
    assert_equal :default, override.field_names_mode
    # Naming never alters inherited restrictions.
    assert_equal parent.field_narrowing_for("FieldNamesSong"), override.field_narrowing_for("FieldNamesSong")
  end

  def song
    s = FNSong.new(title: "Hey", total_plays: 0, is_public: false, external_id: "EXT-1",
                   meta: { "innerKey" => { "deep_key" => [1, { "aB" => false }] } },
                   secret_note: "do not show")
    s.artist = Parse::User.pointer("u1")
    s
  end

  def serialize(agent, value)
    Parse::Agent::FieldPolicy.with(agent) do
      Parse::Agent::FieldNames.with(agent) { Parse::Agent::Tools.send(:serialize_result, value) }
    end
  end

  def test_method_result_objects_serialize_values_under_server_names
    out = serialize(Parse::Agent.new(field_names: :server), song)
    assert_equal "Hey", out["title"], "values, not field types"
    assert_equal 0, out["totalPlays"]
    assert_equal false, out["isPublic"]
    assert_equal "EXT-1", out["ExternalID"]
    assert_equal({ "innerKey" => { "deep_key" => [1, { "aB" => false }] } }, out["meta"])
    assert_equal({ _type: "Pointer", class: "_User", id: "u1" }, out["artist"])
    refute out.key?("secretNote"), "agent_fields projection still applies"
  end

  def test_object_serialization_is_identical_in_both_modes
    # Parse objects already carry server names, so the mode does not change
    # them; the default-mode output is no longer the field-type map either.
    assert_equal serialize(Parse::Agent.new, song), serialize(Parse::Agent.new(field_names: :server), song)
  end

  def test_aggregation_result_from_a_method_follows_the_agent_mode
    row = Parse::AggregationResult.new({ "_id" => "Rock", "totalPlays" => 5, "total_plays" => 1 })
    server = serialize(Parse::Agent.new(field_names: :server), [row]).first
    assert_equal({ "_id" => "Rock", "totalPlays" => 5, "total_plays" => 1 }, server)
    default = serialize(Parse::Agent.new, [row]).first
    assert_equal({ "_id" => "Rock", "total_plays" => 1 }.keys.sort, default.keys.sort)
  end

  def test_restrictions_are_identical_across_modes_and_identities
    narrowing = { FNSong => %i[title external_id] }
    agents = [
      Parse::Agent.new(fields: narrowing),
      Parse::Agent.new(fields: narrowing, field_names: :server),
      Parse::Agent.new(fields: narrowing, acl_user: Parse::User.pointer("u_scope")),
      Parse::Agent.new(fields: narrowing, acl_user: Parse::User.pointer("u_scope"), field_names: :server),
    ]
    outputs = agents.map { |a| serialize(a, song).keys.sort }
    assert_equal 1, outputs.uniq.size, "every mode and identity yields the same permitted fields"
    assert_includes outputs.first, "ExternalID"
    refute_includes outputs.first, "totalPlays"
  end

  def test_concurrent_agents_with_different_modes_are_isolated
    row = Parse::AggregationResult.new({ "_id" => "x", "totalPlays" => 1 })
    server_agent = Parse::Agent.new(field_names: :server)
    default_agent = Parse::Agent.new
    seen = {}
    gate = Queue.new
    t1 = Thread.new do
      Parse::Agent::FieldNames.with(server_agent) do
        gate.pop
        seen[:server] = Parse::Agent::Tools.send(:serialize_result, row).keys
      end
    end
    t2 = Thread.new do
      Parse::Agent::FieldNames.with(default_agent) do
        gate << :go
        seen[:default] = Parse::Agent::Tools.send(:serialize_result, row).keys
      end
    end
    [t1, t2].each(&:join)
    assert_equal %w[_id totalPlays], seen[:server]
    assert_equal %w[_id total_plays], seen[:default]
    assert_equal :default, Parse::Agent::FieldNames.current_mode
  end

  # ---- surfaces that already preserve server names -------------------------

  def test_export_headers_keep_server_names_and_explicit_aliases_win
    sample = { "objectId" => "o1", "totalPlays" => 3, "ExternalID" => "E" }
    inferred = Parse::Agent::Tools.send(:infer_export_columns_from, sample).map { |c| c[:header] }
    assert_equal %w[objectId totalPlays ExternalID], inferred
    specs = Parse::Agent::Tools.send(:normalize_export_columns, [{ "totalPlays" => "Plays" }], sample)
    assert_equal ["Plays"], specs.map { |c| c[:header] }
  end

  def test_search_source_records_keep_server_names_in_both_modes
    raw = { "_id" => "o1", "title" => "Hey", "totalPlays" => 3, "ExternalID" => "E", "secretNote" => "x" }
    outputs = [Parse::Agent.new, Parse::Agent.new(field_names: :server)].map do |a|
      Parse::Retrieval::AgentTool.stub(:convert_to_parse_form, ->(doc, _c) { doc.reject { |k, _| k == "_id" } }) do
        Parse::Agent::FieldPolicy.with(a) do
          Parse::Agent::FieldNames.with(a) do
            Parse::Retrieval::AgentTool.send(:source_projector, a, "FieldNamesSong", nil).call(raw)
          end
        end
      end
    end
    assert_equal outputs.first, outputs.last
    assert_equal({ "title" => "Hey", "totalPlays" => 3, "ExternalID" => "E" }, outputs.first)
  end

  def test_subscription_notifications_carry_no_data_fields
    published = []
    notifier = Object.new
    notifier.define_singleton_method(:publish) { |sid, msg| published << [sid, msg] }
    manager = Parse::Agent::MCPSubscriptions::Manager.new(notifier: notifier, supported: true)
    manager.send(:publish_update, "s1", "parse://FieldNamesSong/samples")
    assert_equal({ "uri" => "parse://FieldNamesSong/samples" }, published.first.last["params"])
  end

  def test_schema_field_names_agree_with_returned_data
    server = { "className" => "FieldNamesSong",
               "fields" => { "objectId" => { "type" => "String" }, "title" => { "type" => "String" },
                             "totalPlays" => { "type" => "Number" }, "ExternalID" => { "type" => "String" },
                             "secretNote" => { "type" => "String" } } }
    schema_keys = Parse::Agent::MetadataRegistry.enriched_schema("FieldNamesSong", server)["fields"].keys
    data_keys = serialize(Parse::Agent.new(field_names: :server), song).keys
    assert_includes schema_keys, "ExternalID"
    assert_includes data_keys, "ExternalID"
    assert_includes schema_keys, "totalPlays"
    assert_includes data_keys, "totalPlays"
    refute_includes schema_keys, "secretNote"
    refute_includes data_keys, "secretNote"
  end
end
