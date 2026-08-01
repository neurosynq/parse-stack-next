# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/authorization"
require "parse/atlas_search"
require "parse/cache/keyspace"
require "parse/cache/sub_cache"

# Unit tests for Parse::Authorization::Context, the resolver that maps
# session tokens to user identities and inherited role sets. Every
# mongo-direct path depends on it: Atlas Search, aggregates, and plain
# direct queries all route through Parse::ACLScope into this resolver.
#
# It used to live in Parse::AtlasSearch::Session, which made a query with no
# $search anywhere in it depend on the Atlas Search namespace to decide who
# the caller was. The state now lives on each Parse::Client, so two clients
# pointed at two applications cannot resolve tokens against each other's
# caches. Both lookups are cached separately (token to user_id, user_id to
# role_names) so several calls in one turn amortize the cost.
class AuthorizationContextTest < Minitest::Test
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
    context.identity_cache.clear
    context.role_cache.clear
  end

  # The context under test: the default client's own, which is what
  # Parse::ACLScope resolves through.
  def context
    Parse.client.authorization
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
    resolved = context.resolve(nil)
    assert_nil resolved.user_id
    assert_predicate resolved, :anonymous?
    assert_equal Set.new, resolved.role_names
    assert_equal ["*"], resolved.permission_strings
  end

  def test_empty_session_token_returns_anonymous_resolved
    resolved = context.resolve("")
    assert_predicate resolved, :anonymous?
    assert_equal ["*"], resolved.permission_strings
  end

  def test_resolve_returns_user_and_roles
    stub_current_user_response(user_id: "U1")
    stub_role_lookup(%w[Member Admin])
    resolved = context.resolve("token-abc")
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
    3.times { context.resolve("token-abc") }
    assert_equal 1, captures.length,
                 "session_token → user_id cache should suppress repeat /users/me calls"
  end

  def test_invalid_session_token_raises_invalidsession
    stub_current_user_error
    assert_raises(Parse::Authorization::InvalidSession) do
      context.resolve("bad-token")
    end
  end

  def test_invalidate_clears_session_cache
    captures = stub_current_user_response(user_id: "U1")
    stub_role_lookup([])
    context.resolve("token-abc")
    context.invalidate("token-abc")
    context.resolve("token-abc")
    assert_equal 2, captures.length, "invalidate should force a re-lookup on next resolve"
  end

  def test_role_lookup_failure_returns_empty_set_not_exception
    stub_current_user_response(user_id: "U1")
    unless Parse::Role.singleton_class.method_defined?(:__test_original_all_for_user)
      Parse::Role.singleton_class.send(:alias_method, :__test_original_all_for_user, :all_for_user)
    end
    Parse::Role.define_singleton_method(:all_for_user) { |*_, **_| raise "simulated" }
    resolved = context.resolve("token-abc")
    assert_equal Set.new, resolved.role_names,
                 "role lookup failure must not propagate — a hiccup in _Role queries " \
                 "should narrow the permission set, not 500 the whole search call"
  end

  def test_permission_strings_dedupe_when_user_id_collides_with_role_format
    # Defensive: if a role were ever named exactly "*", permission_strings
    # must not emit two "*" entries.
    resolved = Parse::Authorization::Resolved.new("*", Set["Admin"])
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
      context.resolve("token-abc")
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
      context.resolve("token-abc")
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
      context.resolve("token-abc")
    end
  end
end

# Verify the MemoryCache primitive used by the default
# {Parse::AtlasSearch::Session} cache layer behaves as expected:
# TTL expiry, invalidate, and Mutex-guarded access.
class AuthorizationMemoryCacheTest < Minitest::Test
  def test_basic_set_and_get
    cache = Parse::Authorization::MemoryCache.new
    cache.set("k", "v", ttl: 60)
    assert_equal "v", cache.get("k")
  end

  def test_missing_key_returns_nil
    cache = Parse::Authorization::MemoryCache.new
    assert_nil cache.get("nope")
  end

  def test_expired_entry_returns_nil
    cache = Parse::Authorization::MemoryCache.new
    cache.set("k", "v", ttl: -1)  # already expired
    assert_nil cache.get("k")
  end

  def test_invalidate_removes_entry
    cache = Parse::Authorization::MemoryCache.new
    cache.set("k", "v", ttl: 60)
    cache.invalidate("k")
    assert_nil cache.get("k")
  end

  def test_clear_drops_everything
    cache = Parse::Authorization::MemoryCache.new
    cache.set("a", 1, ttl: 60)
    cache.set("b", 2, ttl: 60)
    cache.clear
    assert_nil cache.get("a")
    assert_nil cache.get("b")
  end
end

# Unit tests for Task 1: consuming Parse::Cache::SubCache's identity
# generation from Parse::AtlasSearch::Session.lookup_user_id. A _User
# write bumps a user's generation (Parse::Cache::Invalidation); these
# tests confirm the reader actually checks it now, feature-detecting so
# the default MemoryCache (no generation support) keeps working exactly
# as before.
class AuthorizationGenerationTest < Minitest::Test
  def context
    Parse.client.authorization
  end

  # Minimal generation-capable cache double: implements the same surface
  # Parse::Cache::SubCache exposes (get/set/invalidate plus
  # generation/bump_generation/generation_current?) without requiring a
  # real keyspace or backing store.
  class FakeGenCache
    def initialize
      @data = {}
      @gens = Hash.new(0)
    end

    def get(key) = @data[key]
    def set(key, value, ttl: nil) = @data[key] = value
    def invalidate(key) = @data.delete(key)
    def generation(subject) = @gens[subject]
    def bump_generation(subject) = @gens[subject] += 1
    def generation_current?(subject, gen) = @gens[subject] == gen.to_i
  end

  # Bare-bones store satisfying Parse::Cache::SubCache's `[]` / `store` /
  # `delete` contract, used for an end-to-end check against the real
  # SubCache class (not just the double above).
  class FakeKVStore
    def initialize = @data = {}
    def [](k) = @data[k]
    def store(k, v, _o = {}) = @data[k] = v
    def delete(k) = @data.delete(k)
  end

  def setup
    begin
      Parse.client
    rescue Parse::Error::ConnectionError
      Parse.setup(server_url: "http://localhost:9999/parse",
                  application_id: "test-app",
                  api_key: "test-key")
    end
    Parse::AtlasSearch.reset!
    context.identity_cache.clear
    context.role_cache.clear
    stub_role_lookup([])
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

  def stub_role_lookup(names)
    set = Set.new(Array(names))
    unless Parse::Role.singleton_class.method_defined?(:__test_original_all_for_user)
      Parse::Role.singleton_class.send(:alias_method, :__test_original_all_for_user, :all_for_user)
    end
    Parse::Role.define_singleton_method(:all_for_user) { |*_, **_| set }
  end

  def test_generation_match_serves_from_cache
    cache = FakeGenCache.new
    context.identity_cache = cache
    captures = stub_current_user_response(user_id: "U1")

    context.resolve("token-abc")
    context.resolve("token-abc")

    assert_equal 1, captures.length,
                 "a matching generation must serve the cached entry without re-resolving"
  end

  def test_generation_mismatch_forces_reresolution
    cache = FakeGenCache.new
    context.identity_cache = cache
    captures = stub_current_user_response(user_id: "U1")

    context.resolve("token-abc")
    assert_equal 1, captures.length

    # Simulate the _User after_save/after_delete trigger bumping this
    # user's generation (Parse::Cache::Invalidation).
    cache.bump_generation("U1")

    context.resolve("token-abc")
    assert_equal 2, captures.length,
                 "a bumped generation must be treated as a miss and force re-resolution"

    # The re-resolved entry is tagged with the new generation, so a
    # subsequent read is a hit again.
    context.resolve("token-abc")
    assert_equal 2, captures.length,
                 "the re-stored entry must carry the current generation"
  end

  def test_cache_without_generation_support_still_works
    # The default cache after reset! is MemoryCache, which has no
    # generation contract at all.
    refute context.send(:generation_capable?, context.identity_cache)

    captures = stub_current_user_response(user_id: "U1")
    context.resolve("token-abc")
    context.resolve("token-abc")

    assert_equal 1, captures.length,
                 "a non-generation-capable cache must still serve cache hits (today's behavior)"
  end

  def test_legacy_bare_string_value_does_not_crash_the_reader
    cache = FakeGenCache.new
    context.identity_cache = cache
    # Seed a value in the shape written before generation-tagging existed:
    # a bare user id string, not {"user_id" => ..., "gen" => ...}.
    cache.set("token-abc", "LEGACY-U1", ttl: 3600)

    captures = stub_current_user_response(user_id: "U1")

    resolved = nil
    assert_silent_ish { resolved = context.resolve("token-abc") }

    assert_equal "U1", resolved.user_id,
                 "an unrecognized cached shape must be treated as a miss and re-resolved, " \
                 "not returned or allowed to raise"
    assert_equal 1, captures.length
  end

  def test_generation_integration_with_real_subcache
    keyspace = Parse::Cache::Keyspace.new(app_id: "gen-app", server_url: "https://x")
    store = FakeKVStore.new
    identity = Parse::Cache::SubCache.new(store: store, keyspace: keyspace, family: :idn, ttl: 3600)
    context.identity_cache = identity

    captures = stub_current_user_response(user_id: "U1")

    context.resolve("token-abc")
    context.resolve("token-abc")
    assert_equal 1, captures.length

    identity.bump_generation("U1")

    context.resolve("token-abc")
    assert_equal 2, captures.length,
                 "the real SubCache generation counter must invalidate the entry on bump"
  end

  private

  # Minitest doesn't ship `assert_nothing_raised`; this documents intent
  # at the call site while still failing loudly (via the propagated
  # exception) if the block raises.
  def assert_silent_ish
    yield
  end
end

# Unit tests for Task 2: the opt-in, compare-only upstream role read.
# Must never change what Session.resolve returns; must be inert unless
# both context.compare_upstream_roles and
# context.upstream_role_reader are configured; must swallow
# any exception from the reader; and must emit a redacted
# parse.cache.role_compare event (digest only, no role names, no raw
# user id) when configured.
class AuthorizationRoleCompareTest < Minitest::Test
  def context
    Parse.client.authorization
  end

  class FakeUpstreamReader
    attr_accessor :value, :error

    def roles_for(_user_id)
      raise @error if @error
      @value
    end
  end

  def setup
    begin
      Parse.client
    rescue Parse::Error::ConnectionError
      Parse.setup(server_url: "http://localhost:9999/parse",
                  application_id: "test-app",
                  api_key: "test-key")
    end
    Parse::AtlasSearch.reset!
    context.identity_cache.clear
    context.role_cache.clear
  end

  def teardown
    Parse::AtlasSearch.reset!
  end

  def seed_role_cache(user_id, names)
    context.role_cache.set(user_id, Set.new(Array(names)), ttl: 30)
  end

  def capture_role_compare_events
    events = []
    sub = ActiveSupport::Notifications.subscribe("parse.cache.role_compare") do |*args|
      events << ActiveSupport::Notifications::Event.new(*args).payload
    end
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  def test_inert_when_unconfigured
    seed_role_cache("U1", %w[Admin])
    events = capture_role_compare_events do
      names = context.send(:lookup_role_names, "U1")
      assert_equal Set["Admin"], names
    end
    assert_empty events, "no event should be emitted when compare_upstream_roles is off"
  end

  def test_inert_when_compare_enabled_but_no_reader_configured
    context.compare_upstream_roles = true
    context.upstream_role_reader = nil
    seed_role_cache("U1", %w[Admin])
    events = capture_role_compare_events do
      context.send(:lookup_role_names, "U1")
    end
    assert_empty events, "no event should be emitted without an upstream_role_reader"
  end

  def test_compare_mode_never_changes_the_returned_set
    context.compare_upstream_roles = true
    reader = FakeUpstreamReader.new
    reader.value = Set["SomethingElseEntirely"]
    context.upstream_role_reader = reader
    seed_role_cache("U1", %w[Admin])

    names = context.send(:lookup_role_names, "U1")
    assert_equal Set["Admin"], names,
                 "the upstream comparison must be purely diagnostic and never change the result"
  end

  def test_compare_mode_emits_matched_event
    context.compare_upstream_roles = true
    reader = FakeUpstreamReader.new
    reader.value = Set["Admin"]
    context.upstream_role_reader = reader
    seed_role_cache("U1", %w[Admin])

    events = capture_role_compare_events do
      context.send(:lookup_role_names, "U1")
    end

    assert_equal 1, events.length
    payload = events.first
    assert_equal true, payload[:matched]
    assert_equal false, payload[:upstream_nil]
    assert_equal 1, payload[:computed_size]
    assert_equal 1, payload[:upstream_size]
    assert_equal 0, payload[:only_in_ours]
    assert_equal 0, payload[:only_in_upstream]
    refute_includes payload.keys, :role_names
    refute_includes payload.keys, :user_id
    assert payload[:user_digest].is_a?(String)
    refute_includes payload[:user_digest], "U1"
  end

  def test_compare_mode_emits_mismatched_event
    context.compare_upstream_roles = true
    reader = FakeUpstreamReader.new
    reader.value = Set["Other"]
    context.upstream_role_reader = reader
    seed_role_cache("U1", %w[Admin])

    events = capture_role_compare_events do
      context.send(:lookup_role_names, "U1")
    end

    payload = events.first
    assert_equal false, payload[:matched]
    assert_equal 1, payload[:computed_size]
    assert_equal 1, payload[:upstream_size]
    assert_equal 1, payload[:only_in_ours]
    assert_equal 1, payload[:only_in_upstream]
  end

  def test_compare_mode_upstream_nil_event
    context.compare_upstream_roles = true
    reader = FakeUpstreamReader.new
    reader.value = nil
    context.upstream_role_reader = reader
    seed_role_cache("U1", %w[Admin])

    events = capture_role_compare_events do
      context.send(:lookup_role_names, "U1")
    end

    payload = events.first
    assert_equal true, payload[:upstream_nil]
    assert_equal false, payload[:matched]
    assert_nil payload[:upstream_size]
    assert_equal 1, payload[:only_in_ours]
    assert_equal 0, payload[:only_in_upstream]
  end

  def test_exception_from_upstream_reader_is_swallowed
    context.compare_upstream_roles = true
    reader = FakeUpstreamReader.new
    reader.error = RuntimeError.new("simulated upstream failure")
    context.upstream_role_reader = reader
    seed_role_cache("U1", %w[Admin])

    names = nil
    capture_role_compare_events do
      names = context.send(:lookup_role_names, "U1")
    end

    assert_equal Set["Admin"], names,
                 "an upstream reader exception must never affect the returned closure"
  end

  def test_no_upstream_call_when_disabled
    context.compare_upstream_roles = false
    reader = FakeUpstreamReader.new
    def reader.roles_for(_user_id)
      raise "must not be called when compare_upstream_roles is false"
    end
    context.upstream_role_reader = reader
    seed_role_cache("U1", %w[Admin])

    names = context.send(:lookup_role_names, "U1")
    assert_equal Set["Admin"], names
  end
end
