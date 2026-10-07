# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/mongodb"

class ParityAuditRef < Parse::Object
  parse_class "ParityAuditRef"
  property :label, :string
end

class ParityAuditItem < Parse::Object
  parse_class "ParityAuditItem"
  property :name, :string
  property :meta, :object
  property :doc, :file
  property :tags, :array
  belongs_to :owner, as: :user
  belongs_to :ref, as: :parity_audit_ref
end

# REST vs mongo-direct parity for Parse::Query's direct path: which
# identity a direct read runs as, the pipeline it compiles, and how the
# rows decode. Pure unit tests; no live MongoDB.
class ParityAuditDirectQueryTest < Minitest::Test
  SERVER = "http://localhost:1337/parse"

  def setup
    @prior_mode = Parse.client_mode
    Parse.setup(server_url: SERVER, application_id: "test", api_key: "test",
                master_key: "mk") unless Parse::Client.client?
  end

  def teardown
    Parse.client_mode = @prior_mode
  end

  def non_master_client(session_token: nil)
    Parse::Client.new(server_url: SERVER, app_id: "test", api_key: "test",
                      master_key: nil, session_token: session_token)
  end

  def master_client
    Parse::Client.new(server_url: SERVER, app_id: "test", api_key: "test", master_key: "mk")
  end

  def query_on(client)
    q = ParityAuditItem.query
    q.client = client
    q
  end

  def scope_of(query)
    query.send(:mongo_direct_auth_kwargs).reject { |k, _| k == :client }
  end

  # ------------------------------------------------------------------ U2

  def test_become_client_scopes_direct_reads_to_its_session
    q = query_on(master_client.become("r:bob"))
    assert_equal({ session_token: "r:bob" }, scope_of(q))
  end

  def test_session_client_style_client_scopes_direct_reads
    q = query_on(non_master_client(session_token: "r:carol"))
    assert_equal({ session_token: "r:carol" }, scope_of(q))
  end

  def test_tokenless_non_master_client_runs_public_not_master
    assert_equal({}, scope_of(query_on(non_master_client)))
  end

  def test_use_master_key_false_runs_public_not_master
    q = query_on(master_client)
    q.use_master_key = false
    assert_equal({}, scope_of(q))
  end

  def test_client_mode_runs_public_not_master
    Parse.client_mode = true
    assert_equal({}, scope_of(query_on(master_client)))
  end

  def test_client_mode_with_explicit_master_key_runs_master
    Parse.client_mode = true
    q = query_on(master_client)
    q.use_master_key = true
    assert_equal({ master: true }, scope_of(q))
  end

  def test_server_mode_master_client_keeps_master_default
    assert_equal({ master: true }, scope_of(query_on(master_client)))
  end

  def test_ambient_session_wins_over_bound_session
    q = query_on(non_master_client(session_token: "r:bound"))
    Parse.with_session("r:ambient") do
      assert_equal({ session_token: "r:ambient" }, scope_of(q))
    end
  end

  def test_results_direct_forwards_bound_session_to_aggregate
    q = query_on(master_client.become("r:bob"))
    seen = nil
    Parse::MongoDB.stub(:available?, true) do
      Parse::MongoDB.stub(:aggregate, ->(_t, _p, **kw) { seen = kw; [] }) do
        q.results_direct
        q.count_direct
      end
    end
    assert_equal "r:bob", seen[:session_token]
    assert_nil seen[:master]
  end

  def test_bound_session_counts_as_scoped_for_aggregations
    assert query_on(master_client.become("r:bob")).send(:distinct_query_is_scoped?)
  end

  # ---------------------------------------------------------- P4 / P9

  def test_includes_with_keys_keeps_the_lookup_output
    q = ParityAuditItem.query.includes(:ref).keys(:name)
    project = q.send(:build_direct_mongodb_pipeline).find { |s| s.key?("$project") }["$project"]
    assert_equal 1, project["_included_ref"]
    assert_equal 1, project["_p_ref"]
  end

  def test_dotted_key_projects_its_top_level_column
    q = ParityAuditItem.query.keys("meta.k")
    project = q.send(:build_direct_mongodb_pipeline).find { |s| s.key?("$project") }["$project"]
    assert_equal 1, project["meta"]
    refute project.key?("meta.k")
  end

  # ------------------------------------------------------------------ P7

  def test_in_query_compiles_to_lookup
    q = ParityAuditItem.query(:ref.in_query => ParityAuditRef.query(label: "L1"))
    pipeline = q.send(:build_direct_mongodb_pipeline)
    refute pipeline.to_s.include?("$inQuery"), pipeline.inspect
    lookup = pipeline.find { |s| s.key?("$lookup") }["$lookup"]
    assert_equal "ParityAuditRef", lookup["from"]
    assert_includes lookup["pipeline"], { "$match" => { "label" => "L1" } }
    post = pipeline.find { |s| s.key?("$match") && s["$match"].keys.any? { |k| k.start_with?("_subquery_") } }
    assert_equal({ "$ne" => [] }, post["$match"].values.first)
    assert pipeline.any? { |s| s.key?("$unset") }
  end

  def test_not_in_query_keeps_rows_with_empty_join
    q = ParityAuditItem.query(:ref.not_in_query => ParityAuditRef.query(label: "L1"))
    pipeline = q.send(:build_direct_mongodb_pipeline)
    post = pipeline.find { |s| s.key?("$match") && s["$match"].keys.any? { |k| k.start_with?("_subquery_") } }
    assert_equal({ "$eq" => [] }, post["$match"].values.first)
  end

  def test_select_compiles_to_lookup_on_key
    q = ParityAuditItem.query(:name.select => { key: :label, query: ParityAuditRef.query })
    pipeline = q.send(:build_direct_mongodb_pipeline)
    refute pipeline.to_s.include?("$select"), pipeline.inspect
    lookup = pipeline.find { |s| s.key?("$lookup") }["$lookup"]
    assert_equal({ "subquery_value" => "$name" }, lookup["let"])
    assert_includes lookup["pipeline"], { "$match" => { "$expr" => { "$eq" => ["$label", "$$subquery_value"] } } }
  end

  def test_contained_by_compiles_to_not_elem_match_nin
    q = ParityAuditItem.query(Parse::Operation.new(:tags, :contained_by) => %w[a b])
    match = q.send(:build_direct_mongodb_pipeline).first["$match"]
    assert_equal({ "tags" => { "$not" => { "$elemMatch" => { "$nin" => %w[a b] } } } }, match)
  end

  def test_count_direct_runs_subquery_stages
    q = ParityAuditItem.query(:ref.in_query => ParityAuditRef.query(label: "L1"))
    seen = nil
    Parse::MongoDB.stub(:available?, true) do
      Parse::MongoDB.stub(:aggregate, ->(_t, p, **_kw) { seen = p; [{ "count" => 3 }] }) do
        assert_equal 3, q.count_direct(master: true)
      end
    end
    assert seen.any? { |s| s.key?("$lookup") }
    assert_equal({ "$count" => "count" }, seen.last)
  end

  # --------------------------------------------------- P3 / P5 / P11

  def test_included_document_decodes_as_object_of_its_class
    doc = {
      "_id" => "i1", "name" => "alpha", "_p_ref" => "ParityAuditRef$r1",
      "_included_ref" => { "_id" => "r1", "label" => "L1" },
    }
    row = Parse::MongoDB.convert_document_to_parse(doc, "ParityAuditItem")
    assert_equal "Object", row["ref"]["__type"]
    assert_equal "ParityAuditRef", row["ref"]["className"]
    item = ParityAuditItem.build(row)
    assert_kind_of ParityAuditRef, item.ref
    assert_equal "L1", item.ref.label
  end

  def test_unresolved_include_drops_the_field_like_rest
    doc = { "_id" => "i1", "_p_ref" => "ParityAuditRef$gone", "_included_ref" => nil }
    row = Parse::MongoDB.convert_document_to_parse(doc, "ParityAuditItem")
    refute row.key?("ref")
  end

  def test_include_without_lookup_output_keeps_pointer
    doc = { "_id" => "i1", "_p_ref" => "ParityAuditRef$r1" }
    row = Parse::MongoDB.convert_document_to_parse(doc, "ParityAuditItem")
    assert_equal({ "__type" => "Pointer", "className" => "ParityAuditRef", "objectId" => "r1" }, row["ref"])
  end

  def test_include_stage_yields_explicit_null_when_unresolved
    stages = ParityAuditItem.query.send(:build_include_lookup_stages, [:ref])
    collapse = stages.find { |s| s.key?("$addFields") && s["$addFields"].key?("_included_ref") }
    refute_nil collapse, stages.inspect
    refute stages.any? { |s| s.key?("$unwind") }
  end

  def test_file_column_decodes_as_rest_file_object
    doc = { "_id" => "i1", "doc" => "abc_f.txt" }
    row = Parse::MongoDB.convert_document_to_parse(doc, "ParityAuditItem")
    file = row["doc"]
    assert_equal "File", file["__type"]
    assert_equal "abc_f.txt", file["name"]
    assert_equal "#{Parse::Client.client.server_url.chomp("/")}/files/#{Parse::Client.client.application_id}/abc_f.txt", file["url"]
  end

  def test_non_file_string_column_is_unchanged
    row = Parse::MongoDB.convert_document_to_parse({ "_id" => "i1", "name" => "f.txt" }, "ParityAuditItem")
    assert_equal "f.txt", row["name"]
  end
end
