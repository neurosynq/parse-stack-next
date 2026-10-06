# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/mongodb"

# Inside a `Parse.without_master_key` block REST sends no master key, so a
# read runs as the session (if any) or anonymously. The mongo-direct
# terminals must resolve the same identity instead of forwarding
# `master: true` and reading every row unrestricted.
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

  # Run `block` with Parse::MongoDB stubbed; returns the auth kwargs the
  # terminal handed to Parse::MongoDB.aggregate.
  def captured_auth
    seen = nil
    agg = lambda do |_table, _pipeline, **kw|
      seen = kw.slice(:session_token, :master, :acl_user, :acl_role).compact
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

  def test_without_master_key_resolves_public_scope
    q = build_query
    assert_equal({}, Parse.without_master_key { scope_of(q) })
    refute Parse.without_master_key { q.send(:mongo_direct_master_posture?) }
  end

  def test_explicit_use_master_key_is_suppressed_like_rest
    q = build_query
    q.use_master_key = true
    assert_equal({}, Parse.without_master_key { scope_of(q) })
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

  def test_results_direct_does_not_forward_master
    q = build_query
    seen = captured_auth { Parse.without_master_key { q.results_direct(raw: true) } }
    assert_equal({}, seen)
  end

  def test_results_direct_explicit_master_kwarg_is_suppressed
    q = build_query
    seen = captured_auth { Parse.without_master_key { q.results_direct(raw: true, master: true) } }
    refute seen.key?(:master), seen.inspect
  end

  def test_count_and_distinct_direct_do_not_forward_master
    q = build_query
    assert_equal({}, captured_auth { Parse.without_master_key { q.count_direct } })
    assert_equal({}, captured_auth { Parse.without_master_key { q.distinct_direct(:name) } })
    seen = captured_auth { Parse.without_master_key { q.count_direct(master: true) } }
    refute seen.key?(:master), seen.inspect
  end

  def test_atlas_search_scope_respects_block
    q = build_query
    q.use_master_key = true
    assert_equal({ master: true }, atlas_scope_of(q))
    assert_equal({}, Parse.without_master_key { atlas_scope_of(q) })
    explicit = Parse.without_master_key { atlas_scope_of(q, master: true) }
    refute explicit.key?(:master), explicit.inspect
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
