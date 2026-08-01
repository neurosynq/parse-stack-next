# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "json"
require "parse/cache/keyspace"
require "parse/cache/sub_cache"
require "parse/cache/upstream_roles"

# Tests the read-only consumer of Parse Server's role cache. Every failure mode
# must degrade to a miss so the caller recomputes; none may fail open, because
# the value feeds permission_strings on the mongo-direct path where the SDK is
# the only enforcement layer.
class CacheUpstreamRolesTest < Minitest::Test
  APP = "myAppId"
  USER = "qjfaJ4u3yt"

  # redis-rb-shaped double.
  class FakeRedis
    attr_accessor :values, :ttls, :raise_on_get
    def initialize = (@values = {}; @ttls = {}; @raise_on_get = false)
    def get(k)
      raise IOError, "boom" if @raise_on_get
      @values[k]
    end
    def pttl(k) = @ttls.fetch(k, -2)
  end

  class FakeStore
    attr_reader :data
    def initialize = @data = {}
    def [](k) = @data[k]
    def store(k, v, _o = {}) = @data[k] = v
    def delete(k) = @data.delete(k)
  end

  def setup
    @redis = FakeRedis.new
    @store = FakeStore.new
    keyspace = Parse::Cache::Keyspace.new(app_id: APP, server_url: "https://x")
    @plane = Parse::Cache::SubCache.new(store: @store, keyspace: keyspace, family: :role, ttl: 30)
    @reader = Parse::Cache::UpstreamRoles.new(client: @redis, app_id: APP, roles_plane: @plane)
  end

  def seed(roles, ttl_ms: 25_000, user: USER)
    key = "#{APP}:role:#{user}"
    @redis.values[key] = JSON.generate(roles)
    @redis.ttls[key] = ttl_ms
    key
  end

  # --- happy path ---------------------------------------------------------

  def test_key_matches_parse_server_layout
    assert_equal "#{APP}:role:#{USER}", @reader.key_for(USER)
  end

  def test_reads_and_strips_exactly_one_role_prefix
    seed(["role:Admin", "role:Viewer"])
    assert_equal Set.new(%w[Admin Viewer]), @reader.roles_for(USER)
  end

  # Real deployments use scoped names containing / and :. A tighter validator
  # would reject every role in such an app and fail closed into no access.
  def test_accepts_scoped_role_names_with_slashes_and_colons
    seed(["role:owner/t:NYz9tjt3cQ/p:3ZUjTajLyy", "role:guest/t:a1dx2u4yA2"])
    assert_equal Set.new(["owner/t:NYz9tjt3cQ/p:3ZUjTajLyy", "guest/t:a1dx2u4yA2"]),
                 @reader.roles_for(USER)
  end

  # Parse Server caches an empty closure as [], which is a hit, not a miss.
  def test_empty_array_is_an_empty_set_not_nil
    seed([])
    assert_equal Set.new, @reader.roles_for(USER)
  end

  def test_does_not_double_prefix
    seed(["role:Admin"])
    assert_includes @reader.roles_for(USER), "Admin"
    refute_includes @reader.roles_for(USER), "role:Admin"
  end

  # --- misses -------------------------------------------------------------

  def test_absent_key_is_a_miss
    assert_nil @reader.roles_for(USER)
  end

  def test_blank_user_is_a_miss
    assert_nil @reader.roles_for(nil)
    assert_nil @reader.roles_for("")
  end

  def test_transport_error_is_a_miss
    seed(["role:Admin"])
    @redis.raise_on_get = true
    assert_nil @reader.roles_for(USER)
  end

  # --- validation, all fail closed ---------------------------------------

  def test_malformed_json_is_a_miss
    key = "#{APP}:role:#{USER}"
    @redis.values[key] = "not json"
    @redis.ttls[key] = 25_000
    assert_nil @reader.roles_for(USER)
  end

  def test_non_array_is_a_miss
    key = "#{APP}:role:#{USER}"
    @redis.values[key] = JSON.generate({ "role" => "Admin" })
    @redis.ttls[key] = 25_000
    assert_nil @reader.roles_for(USER)
  end

  def test_unprefixed_entry_is_a_miss
    seed(["Admin"])
    assert_nil @reader.roles_for(USER)
  end

  def test_non_string_entry_is_a_miss
    seed(["role:Admin", 42])
    assert_nil @reader.roles_for(USER)
  end

  def test_wildcard_role_is_rejected
    seed(["role:*"])
    assert_nil @reader.roles_for(USER)
  end

  def test_control_characters_are_rejected
    seed(["role:Ad\x00min"])
    assert_nil @reader.roles_for(USER)
  end

  def test_absurd_role_count_is_rejected
    seed(Array.new(Parse::Cache::UpstreamRoles::MAX_ROLE_COUNT + 1) { |i| "role:r#{i}" })
    assert_nil @reader.roles_for(USER)
  end

  # --- age guard ----------------------------------------------------------

  def test_entry_without_expiry_is_rejected
    seed(["role:Admin"], ttl_ms: -1)
    assert_nil @reader.roles_for(USER), "an un-ageable entry must not be trusted"
  end

  def test_entry_with_implausibly_long_ttl_is_rejected
    seed(["role:Admin"], ttl_ms: 10 * 60 * 1000)
    assert_nil @reader.roles_for(USER)
  end

  def test_vanished_key_between_get_and_pttl_is_a_miss
    key = "#{APP}:role:#{USER}"
    @redis.values[key] = JSON.generate(["role:Admin"])
    @redis.ttls[key] = -2
    assert_nil @reader.roles_for(USER)
  end

  # --- epoch gate ---------------------------------------------------------

  # Parse Server keeps serving a deleted role, so our own delete hook is
  # worthless unless a read rejects entries written before that invalidation.
  def test_entry_written_before_the_epoch_is_rejected
    seed(["role:Admin"], ttl_ms: 25_000) # written ~5s ago at a 30s TTL
    @plane.touch_epoch(Time.now.to_f)    # invalidated just now
    assert_nil @reader.roles_for(USER), "a pre-epoch entry must be treated as a miss"
  end

  def test_entry_written_after_the_epoch_is_accepted
    @plane.touch_epoch(Time.now.to_f - 60)
    seed(["role:Admin"], ttl_ms: 29_000)
    assert_equal Set.new(["Admin"]), @reader.roles_for(USER)
  end

  def test_without_a_plane_the_epoch_gate_is_skipped
    reader = Parse::Cache::UpstreamRoles.new(client: @redis, app_id: APP)
    seed(["role:Admin"])
    assert_equal Set.new(["Admin"]), reader.roles_for(USER)
  end

  # --- wrapper integration ------------------------------------------------

  def test_wrapper_exposes_no_upstream_without_a_url
    cache = Parse::Cache::Redis.new(url: "redis://localhost:6379/0")
    assert_nil cache.upstream_roles
    assert_equal true, cache.verify_upstream_isolation!
  end

  # A backend-level `#upstream_roles` has no app id (a keyspace, and
  # therefore an app id, can only be bound via #scoped now), so a direct
  # read can never match a real Parse Server entry.
  def test_bare_upstream_roles_app_id_less_reader_always_misses
    cache = Parse::Cache::Redis.new(url: "redis://localhost:6379/0", parse_cache_url: "redis://localhost:6379/1")
    refute_nil cache.upstream_roles
    assert_nil cache.upstream_roles.app_id.presence
  end

  # Two regression tests live below, for two DIFFERENT bugs that both lived
  # in verify_upstream_isolation! at different points:
  #
  # 1. app_id: nil. `shares_database_with?`'s SCAN pattern became the
  #    literal ":role:*", which can never match a real Parse Server key
  #    (always "<appId>:role:<userId>", no leading colon). That made the
  #    check silently ALWAYS report "isolated", even against a database
  #    that is genuinely shared: a false negative.
  # 2. app_id: "*" with no filtering. Redis (and File.fnmatch) glob "*"
  #    crosses ":" like any other character, so "*:role:*" ALSO matches
  #    this SDK's own role-plane keys
  #    ("parse-stack:v1:<scope>:_:role:userA"). That made the check
  #    ALWAYS report "shared" once the role plane held anything, even on a
  #    database that is genuinely isolated: a false positive, which is
  #    worse than the false negative it replaced because it trains
  #    operators to ignore the warning.
  #
  # The fix keeps the "*" wildcard (so the probe still catches ANY app's
  # cached role) but filters this SDK's own "parse-stack:"-rooted keys out
  # of the scanner's results first.
  # Also serves the sentinel round-trip: `set` / `get` / `del` land in a hash
  # the test can hand to a fake upstream connection to model a database the
  # two endpoints genuinely share.
  class FakeScannableStore
    attr_reader :data

    def initialize(keys, data: {})
      @keys = keys
      @data = data
    end

    def [](_k) = nil
    def key?(_k) = false
    def delete(_k) = nil
    def store(_k, _v, _o = {}) = nil

    def set(k, v, **_opts) = (@data[k] = v) && "OK"
    def get(k) = @data[k]
    def del(k) = @data.delete(k)

    def scan(_cursor, match:, count: 100)
      keys = (@keys + @data.keys).uniq
      ["0", keys.select { |k| File.fnmatch(match, k, File::FNM_NOESCAPE) }]
    end
  end

  # An upstream connection that cannot read anything outside
  # `~<appId>:role:*`, which is the credential this SDK documents.
  class NopermUpstream
    def get(_k) = raise(Redis::CommandError, "NOPERM this user has no permissions")
  end

  def build_backend_scanning(keys, upstream: nil, shared_data: nil)
    backend = Parse::Cache::Redis.new(url: "redis://localhost:6379/0", parse_cache_url: "redis://localhost:6379/1")
    store = FakeScannableStore.new(keys, data: shared_data || {})
    backend.instance_variable_set(:@pool, Parse::Cache::Pool.new(size: 1) { store })
    # Default: an upstream that sees a DIFFERENT database, so the sentinel is
    # absent and isolation is positively established.
    backend.instance_variable_set(:@upstream_client, upstream || FakeScannableStore.new([]))
    backend
  end

  def test_verify_upstream_isolation_detects_a_genuinely_shared_database
    backend = build_backend_scanning(["someRealAppId:role:user123"])
    assert_equal false, backend.verify_upstream_isolation!(on_degraded: :proceed),
                 "a database holding a Parse-Server-shaped role key must be reported as shared"
  end

  # The false-negative regression. An empty scan is equally consistent with a
  # separate database and with a shared one Parse Server has not yet written a
  # role closure to, which is the state of every freshly deployed stack. Only
  # the sentinel round-trip can tell them apart, so a scan that finds nothing
  # must never be reported as isolated on its own.
  def test_verify_upstream_isolation_detects_sharing_before_any_role_key_exists
    shared = {}
    backend = build_backend_scanning(
      [],
      shared_data: shared,
      # Same underlying hash: the upstream connection is looking at the very
      # database we wrote the sentinel to.
      upstream: FakeScannableStore.new([], data: shared),
    )
    assert_equal false, backend.verify_upstream_isolation!(on_degraded: :proceed),
                 "a shared database with no role keys yet must still be reported as shared"
  end

  def test_verify_upstream_isolation_establishes_isolation_via_the_sentinel
    backend = build_backend_scanning(["parse-stack:v1:abc123:_:cache:x:anon"])
    assert_equal true, backend.verify_upstream_isolation!
  end

  # A credential restricted to the role keyspace cannot read the sentinel, and
  # NOPERM says nothing about which database denied it. That is neither
  # isolation nor sharing, and collapsing it into either one is how the
  # original probe came to report every restricted deployment as isolated.
  def test_verify_upstream_isolation_reports_unknown_under_a_restricted_credential
    backend = build_backend_scanning([], upstream: NopermUpstream.new)
    assert_equal :unknown, backend.verify_upstream_isolation!
  end

  def test_unknown_is_truthy_so_existing_callers_are_unaffected
    backend = build_backend_scanning([], upstream: NopermUpstream.new)
    assert backend.verify_upstream_isolation!, "must stay truthy for `if store.verify_upstream_isolation!`"
  end

  def test_verify_upstream_isolation_leaves_no_sentinel_behind
    shared = {}
    backend = build_backend_scanning([], shared_data: shared)
    backend.verify_upstream_isolation!
    assert_empty shared, "the probe key must be deleted once the answer is known"
  end

  # The concrete false-positive regression: this SDK's own role-plane key
  # ("parse-stack:v1:<scope>:_:role:userA") must never be mistaken for a
  # Parse-Server-written entry just because it also matches "*:role:*".
  def test_verify_upstream_isolation_ignores_its_own_role_plane_keys
    backend = build_backend_scanning(["parse-stack:v1:abc123:_:role:userA"])
    assert_equal true, backend.verify_upstream_isolation!,
                 "the SDK's own role-plane keys must never be mistaken for a shared Parse Server database"
  end

  # An application may legitimately be named "parse-stack". Its role keys are
  # then `parse-stack:role:<userId>`, which any filter that rejects keys under
  # the `parse-stack:` prefix would discard, reporting a shared database as
  # isolated. The scanner matches the upstream key SHAPE instead, so the app
  # id is irrelevant.
  def test_verify_upstream_isolation_detects_an_app_named_like_our_own_prefix
    backend = build_backend_scanning(["parse-stack:role:user123"])
    assert_equal false, backend.verify_upstream_isolation!(on_degraded: :proceed),
                 "an app id equal to our keyspace root must not hide a shared database"
  end

  # The alternative fix, rejecting only `parse-stack:v1:`, would break here:
  # `version:` is a constructor parameter, so a keyspace on any other version
  # would have its own role keys counted as Parse Server's, which is the false
  # positive the filter exists to prevent.
  def test_verify_upstream_isolation_ignores_our_role_keys_on_a_nondefault_version
    backend = build_backend_scanning(["parse-stack:v9:abc123:_:role:userA"])
    assert_equal true, backend.verify_upstream_isolation!,
                 "our own role-plane keys must be ignored regardless of keyspace version"
  end

  # A real Parse Server key must still be detected even when this SDK's own
  # role-plane keys are present on the same database.
  def test_verify_upstream_isolation_still_detects_sharing_alongside_its_own_keys
    backend = build_backend_scanning([
      "parse-stack:v1:abc123:_:role:userA",
      "someRealAppId:role:userB",
    ])
    assert_equal false, backend.verify_upstream_isolation!(on_degraded: :proceed)
  end

  def test_keyspace_retains_the_raw_app_id_for_upstream_keys
    ks = Parse::Cache::Keyspace.new(app_id: APP, server_url: "https://x")
    assert_equal APP, ks.app_id
    refute_includes ks.root_prefix, APP, "our own layout must still use the digest"
  end

  # --- shared-database probe ---------------------------------------------

  # The probe scans OUR database for THEIR key pattern. An earlier version wrote
  # a sentinel and read it back through the upstream client, which always
  # reported "isolated" under the restricted ACL this class documents, since the
  # sentinel sits outside the permitted key pattern and returns NOPERM.
  class FakeScanner
    def initialize(keys) = @keys = keys
    def scan(_cursor, match:, count: 100)
      ["0", @keys.select { |k| File.fnmatch(match, k, File::FNM_NOESCAPE) }]
    end
  end

  def test_probe_detects_their_keys_in_our_database
    scanner = FakeScanner.new(["#{APP}:role:#{USER}", "parse-stack:v1:abc:_:cache:x:anon"])
    assert @reader.shares_database_with?(scanner)
  end

  def test_probe_reports_isolated_when_only_our_keys_are_present
    scanner = FakeScanner.new(["parse-stack:v1:abc:_:cache:x:anon", "parse-stack:foc:v1:lock"])
    assert_equal false, @reader.shares_database_with?(scanner)
  end

  def test_probe_ignores_another_apps_role_keys
    scanner = FakeScanner.new(["otherApp:role:#{USER}"])
    assert_equal false, @reader.shares_database_with?(scanner)
  end

  def test_probe_is_inert_without_a_scannable_client
    assert_equal false, @reader.shares_database_with?(Object.new)
  end

  def test_probe_writes_nothing
    scanner = FakeScanner.new([])
    @reader.shares_database_with?(scanner)
    assert_empty @store.data, "the probe must not create keys"
  end

  def test_probe_swallows_a_scan_error
    broken = Object.new
    broken.define_singleton_method(:scan) { |*| raise IOError, "boom" }
    assert_equal false, @reader.shares_database_with?(broken)
  end
end
