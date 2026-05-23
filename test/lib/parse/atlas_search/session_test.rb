# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/atlas_search"

# Unit tests for Parse::AtlasSearch::Session — the resolver that maps
# session tokens to user identities and inherited role sets for the
# Atlas Search ACL injection path. Both lookups are cached separately
# (session_token → user_id, user_id → role_names) so a single agent
# turn that fires multiple search tools amortizes the cost.
class AtlasSearchSessionTest < Minitest::Test
  def setup
    # Parse.client needs a configured client; stub it out unconditionally
    # because the test never actually issues HTTP and the real Parse.setup
    # would require live server config.
    begin
      Parse.client
    rescue Parse::Error::ConnectionError
      Parse.setup(server_url: "http://localhost:9999/parse",
                  application_id: "test-app",
                  api_key: "test-key")
    end
    Parse::AtlasSearch.reset!
    Parse::AtlasSearch.session_cache.clear
    Parse::AtlasSearch.role_cache.clear
  end

  def teardown
    Parse::AtlasSearch.reset!
    if Parse::Role.singleton_class.method_defined?(:__test_original_all_for_user)
      Parse::Role.singleton_class.send(:alias_method, :all_for_user, :__test_original_all_for_user)
      Parse::Role.singleton_class.send(:remove_method, :__test_original_all_for_user)
    end
  end

  def stub_current_user_response(user_id:)
    captures = []
    stub_response = Object.new
    stub_response.define_singleton_method(:error?) { false }
    stub_response.define_singleton_method(:result) { { "objectId" => user_id } }

    Parse.client.define_singleton_method(:current_user) do |token, **_|
      captures << token
      stub_response
    end
    captures
  end

  def stub_current_user_error
    stub_response = Object.new
    stub_response.define_singleton_method(:error?) { true }
    Parse.client.define_singleton_method(:current_user) { |_, **_| stub_response }
  end

  def stub_role_lookup(names)
    set = Set.new(Array(names))
    unless Parse::Role.singleton_class.method_defined?(:__test_original_all_for_user)
      Parse::Role.singleton_class.send(:alias_method, :__test_original_all_for_user, :all_for_user)
    end
    Parse::Role.define_singleton_method(:all_for_user) { |*_, **_| set }
  end

  def test_nil_session_token_returns_anonymous_resolved
    resolved = Parse::AtlasSearch::Session.resolve(nil)
    assert_nil resolved.user_id
    assert_predicate resolved, :anonymous?
    assert_equal Set.new, resolved.role_names
    assert_equal ["*"], resolved.permission_strings
  end

  def test_empty_session_token_returns_anonymous_resolved
    resolved = Parse::AtlasSearch::Session.resolve("")
    assert_predicate resolved, :anonymous?
    assert_equal ["*"], resolved.permission_strings
  end

  def test_resolve_returns_user_and_roles
    stub_current_user_response(user_id: "U1")
    stub_role_lookup(%w[Member Admin])
    resolved = Parse::AtlasSearch::Session.resolve("token-abc")
    assert_equal "U1", resolved.user_id
    assert_equal Set["Member", "Admin"], resolved.role_names
    assert_includes resolved.permission_strings, "*"
    assert_includes resolved.permission_strings, "U1"
    assert_includes resolved.permission_strings, "role:Member"
    assert_includes resolved.permission_strings, "role:Admin"
  end

  def test_session_token_cache_skips_repeat_lookup
    captures = stub_current_user_response(user_id: "U1")
    stub_role_lookup([])
    3.times { Parse::AtlasSearch::Session.resolve("token-abc") }
    assert_equal 1, captures.length,
                 "session_token → user_id cache should suppress repeat /users/me calls"
  end

  def test_invalid_session_token_raises_invalidsession
    stub_current_user_error
    assert_raises(Parse::AtlasSearch::Session::InvalidSession) do
      Parse::AtlasSearch::Session.resolve("bad-token")
    end
  end

  def test_invalidate_clears_session_cache
    captures = stub_current_user_response(user_id: "U1")
    stub_role_lookup([])
    Parse::AtlasSearch::Session.resolve("token-abc")
    Parse::AtlasSearch::Session.invalidate("token-abc")
    Parse::AtlasSearch::Session.resolve("token-abc")
    assert_equal 2, captures.length, "invalidate should force a re-lookup on next resolve"
  end

  def test_role_lookup_failure_returns_empty_set_not_exception
    stub_current_user_response(user_id: "U1")
    unless Parse::Role.singleton_class.method_defined?(:__test_original_all_for_user)
      Parse::Role.singleton_class.send(:alias_method, :__test_original_all_for_user, :all_for_user)
    end
    Parse::Role.define_singleton_method(:all_for_user) { |*_, **_| raise "simulated" }
    resolved = Parse::AtlasSearch::Session.resolve("token-abc")
    assert_equal Set.new, resolved.role_names,
                 "role lookup failure must not propagate — a hiccup in _Role queries " \
                 "should narrow the permission set, not 500 the whole search call"
  end

  def test_permission_strings_dedupe_when_user_id_collides_with_role_format
    # Defensive: if a role were ever named exactly "*", permission_strings
    # must not emit two "*" entries.
    resolved = Parse::AtlasSearch::Session::Resolved.new("*", Set["Admin"])
    perms = resolved.permission_strings
    assert_equal 1, perms.count("*")
  end

  # ATLAS-7: the role-lookup rescue must NOT swallow attack signals.
  # DeniedOperator (someone probed a $where injection via a role query),
  # ExecutionTimeout (the role traversal exceeded its budget — possibly
  # a slow-loris attack), and CLPScope::Denied (the role-graph walker
  # tripped a CLP) all need to surface to the caller. Swallowing them
  # silently downgrades the call to public-only ACL, which is a fail-
  # open posture.
  def test_role_lookup_re_raises_denied_operator
    stub_current_user_response(user_id: "U1")
    unless Parse::Role.singleton_class.method_defined?(:__test_original_all_for_user)
      Parse::Role.singleton_class.send(:alias_method, :__test_original_all_for_user, :all_for_user)
    end
    Parse::Role.define_singleton_method(:all_for_user) do |*_, **_|
      raise Parse::MongoDB::DeniedOperator, "denied operator probe"
    end
    assert_raises(Parse::MongoDB::DeniedOperator) do
      Parse::AtlasSearch::Session.resolve("token-abc")
    end
  end

  def test_role_lookup_re_raises_execution_timeout
    stub_current_user_response(user_id: "U1")
    unless Parse::Role.singleton_class.method_defined?(:__test_original_all_for_user)
      Parse::Role.singleton_class.send(:alias_method, :__test_original_all_for_user, :all_for_user)
    end
    Parse::Role.define_singleton_method(:all_for_user) do |*_, **_|
      raise Parse::MongoDB::ExecutionTimeout.new(
        collection_name: "_Role",
        max_time_ms: 100,
      )
    end
    assert_raises(Parse::MongoDB::ExecutionTimeout) do
      Parse::AtlasSearch::Session.resolve("token-abc")
    end
  end

  def test_role_lookup_re_raises_clp_denied
    stub_current_user_response(user_id: "U1")
    unless Parse::Role.singleton_class.method_defined?(:__test_original_all_for_user)
      Parse::Role.singleton_class.send(:alias_method, :__test_original_all_for_user, :all_for_user)
    end
    Parse::Role.define_singleton_method(:all_for_user) do |*_, **_|
      raise Parse::CLPScope::Denied.new("_Role", :find, "CLP refuses find on _Role")
    end
    assert_raises(Parse::CLPScope::Denied) do
      Parse::AtlasSearch::Session.resolve("token-abc")
    end
  end
end

# Verify the MemoryCache primitive used by the default
# {Parse::AtlasSearch::Session} cache layer behaves as expected:
# TTL expiry, invalidate, and Mutex-guarded access.
class AtlasSearchMemoryCacheTest < Minitest::Test
  def test_basic_set_and_get
    cache = Parse::AtlasSearch::Session::MemoryCache.new
    cache.set("k", "v", ttl: 60)
    assert_equal "v", cache.get("k")
  end

  def test_missing_key_returns_nil
    cache = Parse::AtlasSearch::Session::MemoryCache.new
    assert_nil cache.get("nope")
  end

  def test_expired_entry_returns_nil
    cache = Parse::AtlasSearch::Session::MemoryCache.new
    cache.set("k", "v", ttl: -1)  # already expired
    assert_nil cache.get("k")
  end

  def test_invalidate_removes_entry
    cache = Parse::AtlasSearch::Session::MemoryCache.new
    cache.set("k", "v", ttl: 60)
    cache.invalidate("k")
    assert_nil cache.get("k")
  end

  def test_clear_drops_everything
    cache = Parse::AtlasSearch::Session::MemoryCache.new
    cache.set("a", 1, ttl: 60)
    cache.set("b", 2, ttl: 60)
    cache.clear
    assert_nil cache.get("a")
    assert_nil cache.get("b")
  end
end
