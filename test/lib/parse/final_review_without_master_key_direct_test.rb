# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/mongodb"
require "parse/atlas_search"

# Inside a `Parse.without_master_key` block REST sends no master key, so a
# read runs as the session (if any) or anonymously. The mongo-direct
# terminals must resolve the same identity instead of reading every row
# unrestricted. The query layer still forwards `master: true`; the
# resolver (Parse::ACLScope / Parse::AtlasSearch) drops it, so the
# downgrade is reported once, with the block-specific diagnostics.
class FinalReviewWithoutMasterKeyDirectTest < Minitest::Test
  SERVER = "http://localhost:1337/parse"
  AMBIENT = "r:ambient-user-token"

  def setup
    @prior_mode = Parse.client_mode
    Parse.client_mode = false
    Parse.setup(server_url: SERVER, application_id: "test", api_key: "test",
                master_key: "mk") unless Parse::Client.client?
  end

  def teardown
    Parse.client_mode = @prior_mode
  end

  def build_query
    q = Parse::Query.new("FRDirectThing")
    q.client = Parse::Client.new(server_url: SERVER, app_id: "test", api_key: "test", master_key: "mk")
    q
  end

  def scope_of(query)
    query.send(:mongo_direct_auth_kwargs).reject { |k, _| k == :client }
  end

  def atlas_scope_of(query, options = {})
    query.send(:atlas_search_auth_kwargs, options).reject { |k, _| k == :client }
  end

  # Run `block` with Parse::MongoDB stubbed; returns the Resolution
  # Parse::ACLScope produces for the auth kwargs the terminal handed to
  # Parse::MongoDB.aggregate (resolved inside the caller's block).
  def captured_auth
    seen = nil
    agg = lambda do |_table, _pipeline, **kw|
      auth = kw.slice(:session_token, :master, :acl_user, :acl_role).compact
      seen = Parse::ACLScope.resolve!(auth, method_name: :test)
      [{ "count" => 0 }]
    end
    Parse::MongoDB.stub(:require_gem!, nil) do
      Parse::MongoDB.stub(:available?, true) do
        Parse::MongoDB.stub(:aggregate, agg) { yield }
      end
    end
    seen
  end

  def test_baseline_outside_block_is_master
    assert_equal({ master: true }, scope_of(build_query))
  end

  def resolve_in_block(kwargs)
    Parse.without_master_key { Parse::ACLScope.resolve!(kwargs.dup, method_name: :test) }
  end

  def test_without_master_key_resolves_public_scope
    q = build_query
    r = resolve_in_block(Parse.without_master_key { scope_of(q) })
    assert r.public?
    assert r.master_dropped?
  end

  def test_explicit_use_master_key_is_suppressed_like_rest
    q = build_query
    q.use_master_key = true
    r = resolve_in_block(Parse.without_master_key { scope_of(q) })
    assert r.public?
    assert r.master_dropped?
  end

  def test_ambient_session_still_applies_inside_block
    q = build_query
    kwargs = Parse.with_session(AMBIENT) { Parse.without_master_key { scope_of(q) } }
    assert_equal({ session_token: AMBIENT }, kwargs)
  end

  def test_nested_with_master_key_restores_master
    q = build_query
    kwargs = Parse.without_master_key { Parse.with_master_key { scope_of(q) } }
    assert_equal({ master: true }, kwargs)
  end

  def assert_dropped_to_public(resolution)
    assert resolution.public?, resolution.inspect
    assert resolution.master_dropped?, resolution.inspect
  end

  def test_results_direct_does_not_run_as_master
    q = build_query
    assert_dropped_to_public(captured_auth { Parse.without_master_key { q.results_direct(raw: true) } })
  end

  def test_results_direct_explicit_master_kwarg_is_suppressed
    q = build_query
    assert_dropped_to_public(captured_auth { Parse.without_master_key { q.results_direct(raw: true, master: true) } })
  end

  def test_count_and_distinct_direct_do_not_run_as_master
    q = build_query
    assert_dropped_to_public(captured_auth { Parse.without_master_key { q.count_direct } })
    assert_dropped_to_public(captured_auth { Parse.without_master_key { q.distinct_direct(:name) } })
    assert_dropped_to_public(captured_auth { Parse.without_master_key { q.count_direct(master: true) } })
  end

  def test_dropped_master_does_not_burn_the_no_acl_banner
    Parse::ACLScope.reset_warning_state!
    q = build_query
    _out, err = capture_io { captured_auth { Parse.without_master_key { q.count_direct } } }
    refute_match(/mongo-direct/i, err)
  ensure
    Parse::ACLScope.reset_warning_state!
  end

  def test_dropped_master_under_require_session_token_names_the_block
    prior = Parse::ACLScope.require_session_token
    Parse::ACLScope.require_session_token = true
    q = build_query
    err = assert_raises(Parse::ACLScope::ACLRequired) do
      captured_auth { Parse.without_master_key { q.count_direct } }
    end
    assert_match(/without_master_key/, err.message)
  ensure
    Parse::ACLScope.require_session_token = prior
  end

  def test_atlas_search_scope_respects_block
    q = build_query
    q.use_master_key = true
    assert_equal({ master: true }, atlas_scope_of(q))
    Parse.without_master_key do
      r = Parse::AtlasSearch.send(:resolve_scope!, atlas_scope_of(q), method_name: :search)
      assert_dropped_to_public(r)
      r = Parse::AtlasSearch.send(:resolve_scope!, atlas_scope_of(q, master: true), method_name: :search)
      assert_dropped_to_public(r)
    end
  end

  def test_direct_only_route_requires_a_scope_inside_block
    q = build_query
    Parse::MongoDB.stub(:enabled?, true) do
      q.send(:assert_mongo_direct_routable!)
      assert_raises(Parse::Query::MongoDirectRequired) do
        Parse.without_master_key { q.send(:assert_mongo_direct_routable!) }
      end
      Parse.with_session(AMBIENT) do
        Parse.without_master_key { q.send(:assert_mongo_direct_routable!) }
      end
    end
  end
end
