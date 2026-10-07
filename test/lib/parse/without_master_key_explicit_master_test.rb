# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/mongodb"
require "parse/atlas_search"

# Inside `Parse.without_master_key` an explicit `master: true` handed to
# Parse::ACLScope (Parse::MongoDB.aggregate, vector search, agent tools for
# master-key agents) is dropped and the call runs in the public scope, as the
# REST request would once the block strips its master key. SDK metadata
# calls that need master (index stats, Atlas Search index listing) keep it.
class WithoutMasterKeyExplicitMasterTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1/parse", application_id: "a",
                  api_key: "k", master_key: "mk")
    end
    @prior_require = Parse::ACLScope.require_session_token
    Parse::ACLScope.require_session_token = false
  end

  def teardown
    Parse::ACLScope.require_session_token = @prior_require
  end

  def resolve(**opts)
    Parse::ACLScope.resolve!(opts, method_name: :test)
  end

  def test_master_outside_block_is_master
    assert resolve(master: true).master?
  end

  def test_master_inside_block_runs_public
    r = Parse.without_master_key { resolve(master: true) }
    assert r.public?
    assert_equal ["*"], r.permission_strings
  end

  def test_master_inside_block_does_not_warn
    Parse::ACLScope.reset_warning_state!
    _out, err = capture_io { Parse.without_master_key { resolve(master: true) } }
    assert_empty err
  ensure
    Parse::ACLScope.reset_warning_state!
  end

  def test_nested_with_master_key_restores_master
    r = Parse.without_master_key { Parse.with_master_key { resolve(master: true) } }
    assert r.master?
  end

  def test_require_session_token_refuses_dropped_master
    Parse::ACLScope.require_session_token = true
    err = assert_raises(Parse::ACLScope::ACLRequired) do
      Parse.without_master_key { resolve(master: true) }
    end
    assert_match(/without_master_key/, err.message)
  end

  def test_session_and_master_together_still_rejected_inside_block
    assert_raises(ArgumentError) do
      Parse.without_master_key { resolve(master: true, session_token: "r:x") }
    end
  end

  def test_atlas_search_master_inside_block_runs_public
    opts = { master: true }
    r = Parse.without_master_key do
      capture_io { @res = Parse::AtlasSearch.send(:resolve_scope!, opts, method_name: :search) }
      @res
    end
    refute r.master?
    assert Parse.with_master_key { Parse::AtlasSearch.send(:resolve_scope!, { master: true }, method_name: :search) }.master?
  end

  def test_faceted_search_inside_block_is_refused
    Parse::AtlasSearch.stub(:require_available!, nil) do
      [{ master: true }, {}].each do |opts|
        err = assert_raises(Parse::AtlasSearch::FacetedSearchNotACLSafe) do
          Parse.without_master_key { Parse::AtlasSearch.faceted_search("Song", "rock", { genre: { type: :string, path: "genre" } }, **opts) }
        end
        assert_match(/without_master_key/, err.message)
      end
    end
  end

  def test_role_graph_master_inside_block_is_refused
    assert_raises(Parse::ACLScope::ACLRequired) do
      Parse.without_master_key do
        Parse::MongoDB.send(:authorize_role_graph_call!, :users_in_role_subtree, master: true, as: nil)
      end
    end
  end

  # The aggregate sees `master: true` and resolves it; capture the resolution
  # mode it would run under.
  def capture_aggregate_modes
    modes = []
    agg = lambda do |_coll, _pipeline, **kw|
      modes << Parse::ACLScope.resolve!(kw.slice(:master), method_name: :aggregate).mode
      []
    end
    Parse::MongoDB.stub(:aggregate, agg) { yield }
    modes
  end

  def test_index_stats_keeps_master_inside_block
    modes = capture_aggregate_modes do
      Parse.without_master_key { Parse::MongoDB.index_stats("Thing", master: true) }
    end
    assert_equal [:master], modes
  end

  def test_list_search_indexes_keeps_master_inside_block
    modes = capture_aggregate_modes do
      Parse::AtlasSearch::IndexManager.stub(:cache_indexes, nil) do
        Parse.without_master_key do
          Parse::AtlasSearch::IndexManager.list_indexes("Thing", force_refresh: true)
        end
      end
    end
    assert_equal [:master], modes
  end

  def test_metadata_reads_do_not_lift_the_block
    states = []
    agg = lambda do |_coll, _pipeline, **kw|
      states << Parse.master_key_disabled?
      Parse::ACLScope.resolve!(kw.slice(:master), method_name: :aggregate)
      []
    end
    Parse::MongoDB.stub(:aggregate, agg) do
      Parse.without_master_key { Parse::MongoDB.index_stats("Thing", master: true) }
    end
    assert_equal [true], states, "subscribers and hooks inside the call still see the block"
  end

  def test_metadata_sentinel_is_master_only_for_sdk_calls
    Parse.without_master_key do
      assert Parse::ACLScope.resolve!({ master: Parse::ACLScope::METADATA_MASTER }, method_name: :t).master?
      refute Parse::ACLScope.resolve!({ master: true }, method_name: :t).master?
    end
  end

  # --- REST metadata marker -------------------------------------------------

  class CaptureApp
    attr_reader :headers

    def call(env)
      @headers = env[:request_headers].dup
      Struct.new(:noop) { def on_complete; self; end }.new(nil)
    end
  end

  def run_auth_middleware(headers)
    app = CaptureApp.new
    mw = Parse::Middleware::Authentication.new(app, application_id: "a", master_key: "mk")
    mw.call!({ request_headers: headers })
    app.headers
  end

  def test_middleware_keeps_master_key_for_marked_metadata_request
    marker = Parse::Middleware::Authentication::METADATA_MASTER
    token = Parse::Middleware::Authentication::METADATA_MASTER_TOKEN
    sent = Parse.without_master_key { run_auth_middleware({ marker => token }) }
    assert_equal "mk", sent[Parse::Protocol::MASTER_KEY]
    refute sent.key?(marker), "the marker never leaves the process"
  end

  def test_middleware_ignores_a_forged_marker
    marker = Parse::Middleware::Authentication::METADATA_MASTER
    sent = Parse.without_master_key { run_auth_middleware({ marker => "guess" }) }
    refute sent.key?(Parse::Protocol::MASTER_KEY)
    refute sent.key?(marker)
  end

  def test_client_adds_the_marker_only_for_the_sdk_sentinel
    client = Parse::Client.new(server_url: "http://localhost:1/parse", app_id: "a", api_key: "k", master_key: "mk")
    seen = []
    conn = Object.new
    conn.define_singleton_method(:send) do |_method, _uri, _params, headers|
      seen << headers.dup
      Struct.new(:body).new(Parse::Response.new({}))
    end
    client.instance_variable_set(:@conn, conn)
    marker = Parse::Middleware::Authentication::METADATA_MASTER
    client.request(:get, "schemas/Thing", opts: { use_master_key: true,
                                                  metadata_master: Parse::Client::METADATA_MASTER_REQUEST })
    client.request(:get, "schemas/Thing", opts: { use_master_key: true, metadata_master: true })
    client.request(:get, "schemas/Thing", opts: { metadata_master: Parse::Client::METADATA_MASTER_REQUEST })
    assert_equal Parse::Middleware::Authentication::METADATA_MASTER_TOKEN, seen[0][marker]
    refute seen[1].key?(marker), "a caller-supplied true does not set it"
    refute seen[2].key?(marker), "it rides only on an explicit master request"
  end

  # --- CLP schema cache -----------------------------------------------------

  def test_schema_fetch_failure_inside_block_is_not_cached
    failing = Object.new
    def failing.schema(_name) = Parse::Response.new({ "code" => 119, "error" => "unauthorized" })
    prior = Parse::CLPScope.schema_client
    Parse::CLPScope.schema_client = failing
    Parse::CLPScope.reset_cache!
    entry = Parse.without_master_key { Parse::CLPScope.send(:fetch, "WmkThing") }
    assert_equal :unresolvable, entry.kind
    refute Parse::CLPScope.instance_variable_get(:@cache).values.any? { |e| e.kind == :unresolvable },
           "a failure inside the block must not deny other callers"
    Parse::CLPScope.send(:fetch, "WmkThing")
    assert Parse::CLPScope.instance_variable_get(:@cache).values.any? { |e| e.kind == :unresolvable },
           "outside the block a failure is still negatively cached"
  ensure
    Parse::CLPScope.schema_client = prior
    Parse::CLPScope.reset_cache!
  end

  def test_schema_fetch_is_a_metadata_request
    client = Parse::Client.new(server_url: "http://localhost:1/parse", app_id: "a", api_key: "k", master_key: "mk")
    seen = nil
    client.stub(:request, ->(_m, _path, opts: {}, **_k) { seen = opts; Parse::Response.new({ "classLevelPermissions" => {} }) }) do
      Parse::CLPScope.send(:fetch_schema_response, client, "WmkThing")
    end
    assert_equal true, seen[:use_master_key]
    assert seen[:metadata_master].equal?(Parse::Client::METADATA_MASTER_REQUEST)
  end

  # --- role graph walk ------------------------------------------------------

  def test_role_walk_inside_block_is_a_metadata_read
    seen = []
    finder = lambda do |_table, _query, headers: {}, **opts|
      seen << opts
      Parse::Response.new({ "results" => [] })
    end
    Parse.client.stub(:find_objects, finder) do
      Parse.without_master_key do
        Parse::Role.send(:role_query_all, { users: Parse::User.pointer("U1") })
      end
    end
    assert_equal 1, seen.size
    assert_equal true, seen.first[:use_master_key]
    assert seen.first[:metadata_master].equal?(Parse::Client::METADATA_MASTER_REQUEST)
  end

  # --- notification payload -------------------------------------------------

  def test_aggregate_payload_reports_master_dropped
    payloads = []
    sub = ActiveSupport::Notifications.subscribe("parse.mongodb.aggregate") { |*args| payloads << args.last }
    Parse::MongoDB.stub(:verify_client!, nil) do
      Parse::MongoDB.stub(:assert_no_denied_operators!, ->(*_a, **_k) { raise StopIteration }) do
        Parse.without_master_key do
          assert_raises(StopIteration) { Parse::MongoDB.aggregate("Thing", [], master: true) }
        end
      end
    end
    assert_equal true, payloads.last[:master_dropped]
    assert_equal :anon, payloads.last[:scope]
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end

  # --- LiveQuery ------------------------------------------------------------

  def test_live_query_admin_connect_inside_block_withholds_master_key
    require "parse/live_query"
    client = Parse::LiveQuery::Client.new(url: "wss://example.test", application_id: "a",
                                          client_key: "k", master_key: "mk",
                                          use_master_key: true, auto_connect: false)
    frames = []
    client.define_singleton_method(:send_message) { |m| frames << m }
    capture_io { Parse.without_master_key { client.send(:send_connect_message) } }
    refute frames.last.key?(:masterKey)
    assert client.master_key_withheld?
    # A reconnect (or an explicit connect) made outside the block keeps
    # withholding it: subscriptions created on the socket are not elevated.
    capture_io { client.send(:send_connect_message) }
    refute frames.last.key?(:masterKey)
    client.allow_master_key_connection!
    refute client.master_key_withheld?
    capture_io { client.send(:send_connect_message) }
    assert_equal "mk", frames.last[:masterKey]
  end

  def test_live_query_admin_connect_outside_block_sends_master_key
    require "parse/live_query"
    client = Parse::LiveQuery::Client.new(url: "wss://example.test", application_id: "a",
                                          client_key: "k", master_key: "mk",
                                          use_master_key: true, auto_connect: false)
    frames = []
    client.define_singleton_method(:send_message) { |m| frames << m }
    capture_io { client.send(:send_connect_message) }
    assert_equal "mk", frames.last[:masterKey]
    refute client.master_key_withheld?
  end

  # --- metadata marker stays off stored requests ----------------------------

  def metadata_client(responses)
    client = Parse::Client.new(server_url: "http://localhost:1/parse", app_id: "a", api_key: "k",
                               master_key: "mk", retry_limit: 2)
    seen = []
    conn = Object.new
    conn.define_singleton_method(:send) do |_method, _uri, _params, headers|
      seen << headers.dup
      body = responses.shift
      Struct.new(:body).new(body)
    end
    client.instance_variable_set(:@conn, conn)
    [client, seen]
  end

  def server_error
    r = Parse::Response.new({ "code" => 1, "error" => "unavailable" })
    r.http_status = 503
    r
  end

  def test_marker_is_not_kept_on_the_request_after_a_retry
    marker = Parse::Middleware::Authentication::METADATA_MASTER
    client, seen = metadata_client([server_error, Parse::Response.new({})])
    response = client.stub(:sleep, nil) do
      client.request(:get, "schemas/Thing", opts: { use_master_key: true,
                                                    metadata_master: Parse::Client::METADATA_MASTER_REQUEST })
    end
    assert_equal 2, seen.size
    assert(seen.all? { |h| h[marker] == Parse::Middleware::Authentication::METADATA_MASTER_TOKEN },
           "every attempt still carries the marker on the wire copy")
    refute response.request.headers.key?(marker)
    refute response.request.opts.key?(:metadata_master)
  end

  def test_marker_is_not_kept_on_the_request_of_a_raised_error
    marker = Parse::Middleware::Authentication::METADATA_MASTER
    client, = metadata_client([server_error, server_error, server_error, server_error])
    err = client.stub(:sleep, nil) do
      assert_raises(Parse::Error::ServiceUnavailableError) do
        client.request(:get, "schemas/Thing", opts: { use_master_key: true,
                                                      metadata_master: Parse::Client::METADATA_MASTER_REQUEST })
      end
    end
    req = err.response.request
    refute req.headers.key?(marker)
    refute req.opts.key?(:metadata_master)
  end

  # --- suppressed schema failures -------------------------------------------

  def test_schema_failure_inside_block_is_remembered_briefly_inside_the_block_only
    calls = 0
    failing = Object.new
    failing.define_singleton_method(:schema) do |_name|
      calls += 1
      Parse::Response.new({ "code" => 119, "error" => "unauthorized" })
    end
    prior = Parse::CLPScope.schema_client
    Parse::CLPScope.schema_client = failing
    Parse::CLPScope.reset_cache!
    Parse.without_master_key do
      Parse::CLPScope.send(:fetch, "WmkDown")
      Parse::CLPScope.send(:fetch, "WmkDown")
    end
    assert_equal 1, calls, "a failure inside the block is not refetched on every read"
    Parse::CLPScope.send(:fetch, "WmkDown")
    assert_equal 2, calls, "outside the block the block-only memo is not consulted"
  ensure
    Parse::CLPScope.schema_client = prior
    Parse::CLPScope.reset_cache!
  end

  def test_role_walk_inside_block_bypasses_the_response_cache
    prior_cache = Parse.default_query_cache
    Parse.default_query_cache = true
    seen = []
    finder = lambda do |_table, _query, headers: {}, **opts|
      seen << opts
      Parse::Response.new({ "results" => [] })
    end
    Parse.client.stub(:find_objects, finder) do
      Parse.without_master_key do
        Parse::Role.send(:role_query_all, { users: Parse::User.pointer("U1") })
      end
    end
    assert_equal false, seen.first[:cache]
  ensure
    Parse.default_query_cache = prior_cache
  end

  # --- identity resolution race ---------------------------------------------

  def test_resolve_in_flight_during_an_invalidation_does_not_cache_the_token
    client = Parse::Client.new(server_url: "http://localhost:1/parse", app_id: "race", api_key: "k")
    auth = client.authorization
    me = lambda do |_token, **_opts|
      # The session is revoked while `/users/me` is in flight.
      auth.invalidate_user("U1")
      Parse::Response.new({ "objectId" => "U1" })
    end
    client.stub(:current_user, me) do
      assert_equal "U1", auth.send(:lookup_user_id, "r:revoked")
    end
    assert_nil auth.instance_variable_get(:@identity_cache).get("r:revoked"),
               "an answer that raced an invalidation is not cached"
    client.stub(:current_user, ->(_t, **_o) { Parse::Response.new({ "objectId" => "U1" }) }) do
      auth.send(:lookup_user_id, "r:fresh")
    end
    refute_nil auth.instance_variable_get(:@identity_cache).get("r:fresh")
  end


  def test_atlas_dropped_master_honors_either_strict_flag
    Parse::ACLScope.require_session_token = true
    err = assert_raises(Parse::AtlasSearch::ACLRequired) do
      Parse.without_master_key { Parse::AtlasSearch.send(:resolve_scope!, { master: true }, method_name: :search) }
    end
    assert_match(/without_master_key/, err.message)
  end

  def test_atlas_dropped_master_does_not_warn
    Parse::AtlasSearch.instance_variable_set(:@no_acl_warned, false) if Parse::AtlasSearch.instance_variable_defined?(:@no_acl_warned)
    _out, err = capture_io do
      r = Parse.without_master_key { Parse::AtlasSearch.send(:resolve_scope!, { master: true }, method_name: :search) }
      assert r.master_dropped?
    end
    assert_empty err
  end

end
