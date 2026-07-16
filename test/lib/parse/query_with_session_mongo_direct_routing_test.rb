# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Regression for F1: a query that auto-routes to mongo-direct inside a
# `Parse.with_session(token)` block must be SCOPED to that ambient session,
# not silently run as master with no ACL/CLP enforcement.
#
# The bug: `Parse::Query#mongo_direct_auth_kwargs` consulted only the query
# instance's own `@session_token` / `@acl_user` / `@acl_role` and ignored
# `Parse.current_session_token` (the fiber-local ambient set by
# `with_session`). In server mode it fell through to `{ master: true }`, so a
# geo / `$near` query inside a `with_session` block returned every row of
# every tenant — even though every REST query in the same block was correctly
# scoped to that user.
#
# This drives the routing decision directly (the security-relevant logic);
# it needs no live Mongo connection.
class QueryWithSessionMongoDirectRoutingTest < Minitest::Test
  AMBIENT = "r:ambient-user-token"

  def build_query
    Parse::Query.new("GeoThing")
  end

  def auth_kwargs(query)
    query.send(:mongo_direct_auth_kwargs)
  end

  # ---- the bug being fixed ----------------------------------------------

  def test_ambient_session_scopes_direct_route_instead_of_master
    query = build_query
    kwargs = Parse.with_session(AMBIENT) { auth_kwargs(query) }
    assert_equal({ session_token: AMBIENT }, kwargs,
                 "an active with_session block must scope the mongo-direct read, not run as master")
    refute kwargs.key?(:master),
           "the ambient session must suppress the master-key fallback"
  end

  # ---- precedence parity with the REST path ------------------------------

  def test_explicit_master_key_skips_ambient
    # `use_master_key: true` is a deliberate admin call and must win over the
    # ambient — exactly as Parse::Client#request behaves.
    query = build_query
    query.use_master_key = true
    kwargs = Parse.with_session(AMBIENT) { auth_kwargs(query) }
    assert_equal({ master: true }, kwargs)
  end

  def test_explicit_query_session_token_wins_over_ambient
    query = build_query
    query.session_token = "r:explicit-query-token"
    kwargs = Parse.with_session(AMBIENT) { auth_kwargs(query) }
    assert_equal({ session_token: "r:explicit-query-token" }, kwargs)
  end

  def test_scope_to_role_wins_over_ambient
    query = build_query
    query.scope_to_role("admin")
    kwargs = Parse.with_session(AMBIENT) { auth_kwargs(query) }
    assert_equal({ acl_role: "admin" }, kwargs)
  end

  # ---- baselines that must stay unchanged --------------------------------

  def test_no_ambient_no_scope_still_master
    query = build_query
    assert_equal({ master: true }, auth_kwargs(query),
                 "with no scope and no ambient, the server-mode master fallback is unchanged")
  end

  def test_whitespace_only_ambient_is_rejected_at_source
    # SEC-02: with_session now refuses a blank/whitespace token outright, so a
    # whitespace-only ambient can no longer be established (previously it was
    # stored and later "treated as absent", degrading toward master).
    assert_raises(ArgumentError) do
      Parse.with_session("   ") { auth_kwargs(build_query) }
    end
  end

  def test_ambient_does_not_leak_outside_the_block
    query = build_query
    Parse.with_session(AMBIENT) { auth_kwargs(query) }
    assert_equal({ master: true }, auth_kwargs(query),
                 "the ambient must not affect routing once the with_session block exits")
  end
end
