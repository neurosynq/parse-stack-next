# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/mongodb"
require "parse/pipeline_security"
require "parse/clp_scope"
require "parse/acl_scope"
require "parse/lookup_rewriter"

# The protected-field reference scanner, the CLP row gate, and the
# protected-field strip on the mongo-direct aggregate path must decide on
# one schema entry, read through the client the gate uses.
#
# Before the fix the scanner read the schema with the default client and
# treated an unresolvable schema as "nothing protected". A scan that hit a
# failed fetch, followed by a successful refetch before the gate, let a
# `$match` on a protected field reach MongoDB (a value oracle). In a
# multi-app setup the scanner also read the default application's
# protectedFields while the gate read the resolution's application.
class CLPScopeConsistency584Test < Minitest::Test
  class FakeCollection
    attr_reader :pipelines

    def initialize
      @pipelines = []
    end

    def aggregate(pipeline, _opts = {})
      @pipelines << pipeline
      []
    end

    def with(*)
      self
    end
  end

  Response = Struct.new(:ok, :result) do
    def success?
      ok
    end
  end

  # Schema source that answers from a queue of responses and counts calls.
  class SequencedSchemaClient
    attr_reader :calls

    def initialize(*responses)
      @responses = responses
      @calls = 0
    end

    def schema(_name)
      @calls += 1
      @responses.size > 1 ? @responses.shift : @responses.first
    end
  end

  # A second application's client: holds a master key, identifies itself
  # by server URL and application id, as the CLP cache key expects.
  class AppClient
    attr_reader :server_url, :application_id, :master_key

    def initialize(app_id)
      @server_url = "http://#{app_id}.example/parse"
      @application_id = app_id
      @master_key = "mk-#{app_id}"
    end

    def schema(_name)
      Response.new(false, nil)
    end
  end

  FAIL = Response.new(false, nil)
  PROTECTED_CLP = {
    "find" => { "*" => true },
    "protectedFields" => { "*" => ["ssn"] },
  }.freeze
  OK = Response.new(true, { "classLevelPermissions" => PROTECTED_CLP })

  def setup
    Parse.setup(server_url: "http://localhost:1337/parse",
                application_id: "test", api_key: "test") unless Parse::Client.client?
    Parse::CLPScope.reset_cache!
    Parse::CLPScope.default_protected_fields = nil
    @prior_schema_client = Parse::CLPScope.schema_client
  end

  def teardown
    # A test that runs a second application's request records its scope in
    # Parse::MongoDB's binding registry; clear it so later tests see one app.
    Parse::MongoDB.instance_variable_set(:@observed_app_scopes, nil)
    Parse::CLPScope.schema_client = @prior_schema_client
    Parse::CLPScope.reset_cache!
    Parse::CLPScope.default_protected_fields = nil
  end

  def scoped(client: nil)
    Parse::ACLScope::Resolution.new(mode: :session, permission_strings: ["*", "aliceUid01"],
                                    user_id: "aliceUid01", session: nil, client: client)
  end

  def master
    Parse::ACLScope::Resolution.new(mode: :master, permission_strings: nil, user_id: nil,
                                    session: nil, client: nil)
  end

  # Run aggregate with a fixed resolution and a fake collection. The lookup
  # rewriter runs between the scanner and the CLP gate; clearing the cache
  # there stands in for a TTL expiry at that point.
  def run_aggregate(pipeline, resolution, expire_between: false)
    coll = FakeCollection.new
    rewrite = lambda do |p, **_k|
      Parse::CLPScope.reset_cache! if expire_between
      p
    end
    Parse::ACLScope.stub(:resolve!, ->(*_a, **_k) { resolution }) do
      Parse::LookupRewriter.stub(:auto_rewrite, rewrite) do
        Parse::MongoDB.stub(:collection, ->(*_a, **_k) { coll }) do
          Parse::MongoDB.aggregate("SecretThing", pipeline, session_token: "r:stub")
        end
      end
    end
    coll
  ensure
    @last_collection = coll
  end

  def test_fail_then_succeed_fetch_does_not_let_protected_match_through
    Parse::CLPScope.schema_client = SequencedSchemaClient.new(FAIL, OK)
    assert_raises(Parse::CLPScope::Denied) do
      run_aggregate([{ "$match" => { "ssn" => { "$regex" => "^1" } } }], scoped,
                    expire_between: true)
    end
    assert_empty @last_collection.pipelines, "no pipeline may reach MongoDB"
  end

  def test_one_schema_entry_per_request_despite_expiry
    source = SequencedSchemaClient.new(OK)
    Parse::CLPScope.schema_client = source
    run_aggregate([{ "$match" => { "name" => "x" } }], scoped, expire_between: true)
    assert_equal 1, source.calls, "scanner, gate, and strip must share one schema read"
    assert_equal 1, @last_collection.pipelines.size
  end

  def test_snapshot_is_scoped_to_the_request
    source = SequencedSchemaClient.new(OK)
    Parse::CLPScope.schema_client = source
    Parse::CLPScope.with_snapshot { Parse::CLPScope.protected_fields_for("SecretThing", ["*"]) }
    Parse::CLPScope.reset_cache!
    Parse::CLPScope.protected_fields_for("SecretThing", ["*"])
    assert_equal 2, source.calls
  end

  def test_unresolvable_schema_refuses_scoped_scan
    Parse::CLPScope.schema_client = SequencedSchemaClient.new(FAIL)
    err = assert_raises(Parse::CLPScope::Denied) do
      Parse::PipelineSecurity.refuse_protected_field_references!(
        [{ "$match" => { "ssn" => "123-45-6789" } }], "SecretThing", scoped,
      )
    end
    assert_match(/unresolvable/, err.message)
  end

  def test_unresolvable_joined_class_refuses_scoped_scan
    Parse::CLPScope.__cache_put("SecretThing", clp: { "find" => { "*" => true } })
    Parse::CLPScope.schema_client = SequencedSchemaClient.new(FAIL)
    assert_raises(Parse::CLPScope::Denied) do
      Parse::PipelineSecurity.refuse_protected_field_references!(
        [{ "$lookup" => { "from" => "Other", "localField" => "a", "foreignField" => "b", "as" => "o" } }],
        "SecretThing", scoped,
      )
    end
  end

  def test_scan_uses_resolution_client
    app_b = AppClient.new("appB")
    # The default application has no protected fields on the class; app B does.
    Parse::CLPScope.__cache_put("SecretThing", clp: { "find" => { "*" => true } })
    Parse::CLPScope.__cache_put("SecretThing", clp: PROTECTED_CLP, client: app_b)
    assert_raises(Parse::CLPScope::Denied) do
      Parse::PipelineSecurity.refuse_protected_field_references!(
        [{ "$group" => { "_id" => "$ssn" } }], "SecretThing", scoped(client: app_b),
      )
    end
    # The scanner and the gate agree on the client.
    assert_same app_b, Parse::MongoDB.clp_client_for(scoped(client: app_b))
  end

  def test_scan_without_master_key_client_uses_default
    Parse::CLPScope.__cache_put("SecretThing", clp: PROTECTED_CLP)
    keyless = Struct.new(:server_url, :application_id, :master_key).new("http://x/parse", "x", nil)
    assert_raises(Parse::CLPScope::Denied) do
      Parse::PipelineSecurity.refuse_protected_field_references!(
        [{ "$group" => { "_id" => "$ssn" } }], "SecretThing", scoped(client: keyless),
      )
    end
  end

  def test_master_unaffected_by_unresolvable_schema
    source = SequencedSchemaClient.new(FAIL)
    Parse::CLPScope.schema_client = source
    Parse::PipelineSecurity.refuse_protected_field_references!(
      [{ "$match" => { "ssn" => "x" } }], "SecretThing", master,
    )
    run_aggregate([{ "$match" => { "ssn" => "x" } }], master)
    assert_equal 1, @last_collection.pipelines.size
    assert_equal 0, source.calls, "master never reads the schema"
  end

  def test_non_strict_protected_fields_for_still_returns_empty
    Parse::CLPScope.schema_client = SequencedSchemaClient.new(FAIL)
    assert_empty Parse::CLPScope.protected_fields_for("SecretThing", ["*"])
  end

  # Two applications in one process with conflicting schemas for the same
  # class. Each request must be judged by its own application's CLP, in both
  # directions, through the full aggregate path (scanner, gate, and strip).
  def test_conflicting_app_schemas_full_aggregate_path_both_directions
    Parse::MongoDB.stub(:verify_client!, nil) { conflicting_app_aggregate_checks }
  end

  def conflicting_app_aggregate_checks
    app_b = AppClient.new("appB")
    probe = [{ "$group" => { "_id" => "$ssn" } }]

    # Default app: nothing protected. App B: ssn protected.
    Parse::CLPScope.__cache_put("SecretThing", clp: { "find" => { "*" => true } })
    Parse::CLPScope.__cache_put("SecretThing", clp: PROTECTED_CLP, client: app_b)
    assert_raises(Parse::CLPScope::Denied) { run_aggregate(probe, scoped(client: app_b)) }
    assert_empty @last_collection.pipelines, "app B's protected field must not reach MongoDB"
    run_aggregate(probe, scoped)
    assert_equal 1, @last_collection.pipelines.size, "the default app allows it"

    # Reverse: default app protects ssn, app B does not.
    Parse::CLPScope.reset_cache!
    Parse::CLPScope.__cache_put("SecretThing", clp: PROTECTED_CLP)
    Parse::CLPScope.__cache_put("SecretThing", clp: { "find" => { "*" => true } }, client: app_b)
    assert_raises(Parse::CLPScope::Denied) { run_aggregate(probe, scoped) }
    assert_empty @last_collection.pipelines
    run_aggregate(probe, scoped(client: app_b))
    assert_equal 1, @last_collection.pipelines.size, "app B allows it"
  end

  def test_conflicting_app_schemas_atlas_search_uses_requesting_app
    Parse::MongoDB.stub(:verify_client!, nil) { conflicting_app_atlas_checks }
  end

  def conflicting_app_atlas_checks
    require "parse/atlas_search"
    app_b = AppClient.new("appB")
    Parse::CLPScope.__cache_put("SecretThing", clp: { "find" => { "*" => true } })
    Parse::CLPScope.__cache_put("SecretThing", clp: PROTECTED_CLP, client: app_b)
    stage = { "$search" => { "index" => "default", "text" => { "query" => "x", "path" => "ssn" } } }
    coll = FakeCollection.new
    Parse::AtlasSearch.stub(:require_available!, nil) do
      Parse::MongoDB.stub(:collection, ->(*_a, **_k) { coll }) do
        Parse::AtlasSearch.stub(:resolve_scope!, ->(*_a, **_k) { scoped(client: app_b) }) do
          assert_raises(Parse::CLPScope::Denied) do
            Parse::AtlasSearch.search_with_stage("SecretThing", stage, session_token: "r:stub")
          end
        end
        assert_empty coll.pipelines
        Parse::AtlasSearch.stub(:resolve_scope!, ->(*_a, **_k) { scoped }) do
          Parse::AtlasSearch.search_with_stage("SecretThing", stage, session_token: "r:stub")
        end
        assert_equal 1, coll.pipelines.size, "the default app does not protect ssn"
      end
    end
  end

  def test_fail_then_succeed_fetch_refused_on_atlas_search
    require "parse/atlas_search"
    Parse::CLPScope.schema_client = SequencedSchemaClient.new(FAIL, OK)
    stage = { "$search" => { "index" => "default", "text" => { "query" => "x", "path" => "ssn" } } }
    coll = FakeCollection.new
    Parse::AtlasSearch.stub(:require_available!, nil) do
      Parse::MongoDB.stub(:collection, ->(*_a, **_k) { coll }) do
        Parse::AtlasSearch.stub(:resolve_scope!, ->(*_a, **_k) { scoped }) do
          assert_raises(Parse::CLPScope::Denied) do
            Parse::AtlasSearch.search_with_stage("SecretThing", stage, session_token: "r:stub")
          end
        end
      end
    end
    assert_empty coll.pipelines
  end
end
