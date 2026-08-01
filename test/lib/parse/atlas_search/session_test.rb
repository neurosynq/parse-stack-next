# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/atlas_search"

# Parse::AtlasSearch::Session is now a compatibility shim over
# Parse::Authorization. The resolver's own behavior is tested in
# test/lib/parse/authorization_test.rb; what is tested here is only that the
# deprecated surface still reaches the same state, since that is the promise
# made to code written against 5.6 and earlier.
#
# The distinction that matters: these module-level methods take no `client:`,
# so they can only ever address `Parse.client`. That limitation is the reason
# the state moved onto the client, and it is why these are slated for removal
# in 6.0 rather than kept indefinitely.
class AtlasSearchSessionShimTest < Minitest::Test
  def setup
    begin
      Parse.client
    rescue Parse::Error::ConnectionError
      Parse.setup(server_url: "http://localhost:9999/parse",
                  application_id: "test-app",
                  api_key: "test-key")
    end
    Parse::AtlasSearch.reset!
  end

  def context
    Parse.client.authorization
  end

  # --- constants are the same objects, not parallel definitions ----------

  # Aliased rather than subclassed on purpose: a subclass would mean
  # `rescue Parse::AtlasSearch::Session::InvalidSession` no longer catches
  # what the resolver actually raises.
  def test_invalid_session_is_the_same_class_the_resolver_raises
    assert_same Parse::Authorization::InvalidSession,
                Parse::AtlasSearch::Session::InvalidSession
  end

  def test_resolved_is_the_same_struct
    assert_same Parse::Authorization::Resolved,
                Parse::AtlasSearch::Session::Resolved
  end

  def test_memory_cache_is_the_same_class
    assert_same Parse::Authorization::MemoryCache,
                Parse::AtlasSearch::Session::MemoryCache
  end

  # --- module accessors read and write the client's context --------------

  def test_session_cache_reads_the_clients_identity_plane
    assert_same context.identity_cache, Parse::AtlasSearch.session_cache
  end

  def test_session_cache_writer_installs_onto_the_client
    replacement = Parse::Authorization::MemoryCache.new
    Parse::AtlasSearch.session_cache = replacement
    assert_same replacement, context.identity_cache
  end

  def test_role_cache_writer_installs_onto_the_client
    replacement = Parse::Authorization::MemoryCache.new
    Parse::AtlasSearch.role_cache = replacement
    assert_same replacement, context.role_cache
  end

  # session_cache_ttl is the old name for identity_cache_ttl. The plane never
  # stored `_Session` rows or session objects, only one user id per token.
  def test_session_cache_ttl_maps_to_identity_cache_ttl
    Parse::AtlasSearch.session_cache_ttl = 1234
    assert_equal 1234, context.identity_cache_ttl
    assert_equal 1234, Parse::AtlasSearch.session_cache_ttl
  end

  def test_role_cache_ttl_delegates
    Parse::AtlasSearch.role_cache_ttl = 7
    assert_equal 7, context.role_cache_ttl
  end

  def test_upstream_reader_and_compare_switch_delegate
    reader = Object.new
    Parse::AtlasSearch.upstream_role_reader = reader
    Parse::AtlasSearch.compare_upstream_roles = true
    assert_same reader, context.upstream_role_reader
    assert_equal true, context.compare_upstream_roles
  end

  # AtlasSearch.configure forwards the authorization kwargs rather than
  # keeping a second copy, so there is exactly one place the values live.
  def test_configure_forwards_to_the_context
    Parse::AtlasSearch.configure(session_cache_ttl: 99, role_cache_ttl: 11)
    assert_equal 99, context.identity_cache_ttl
    assert_equal 11, context.role_cache_ttl
  end

  # require_session_token is Atlas Search policy (may $search run
  # anonymously), not identity mechanism, so it deliberately did NOT move.
  def test_require_session_token_stays_on_atlas_search
    Parse::AtlasSearch.require_session_token = true
    assert_equal true, Parse::AtlasSearch.require_session_token
    refute context.respond_to?(:require_session_token)
  ensure
    Parse::AtlasSearch.require_session_token = false
  end

  # --- delegated methods -------------------------------------------------

  def test_resolve_returns_anonymous_for_a_blank_token
    resolved = Parse::AtlasSearch::Session.resolve(nil)
    assert resolved.anonymous?
    assert_equal ["*"], resolved.permission_strings
  end

  def test_invalidate_evicts_from_the_clients_identity_plane
    context.identity_cache.set("r:tok", "user123", ttl: 60)
    Parse::AtlasSearch::Session.invalidate("r:tok")
    assert_nil context.identity_cache.get("r:tok")
  end

  def test_invalidate_user_roles_evicts_from_the_clients_role_plane
    context.role_cache.set("user123", Set.new(["Admin"]), ttl: 60)
    Parse::AtlasSearch::Session.invalidate_user_roles("user123")
    assert_nil context.role_cache.get("user123")
  end

  def test_reset_caches_clears_both_planes
    context.identity_cache.set("r:tok", "user123", ttl: 60)
    context.role_cache.set("user123", Set.new(["Admin"]), ttl: 60)
    Parse::AtlasSearch::Session.reset_caches!
    assert_nil context.identity_cache.get("r:tok")
    assert_nil context.role_cache.get("user123")
  end
end
