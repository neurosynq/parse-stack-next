# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/mongodb"
require "parse/atlas_search"

# Integration tests for Atlas Search index MUTATION primitives + the
# mongo_search_index DSL + Parse::Schema::SearchIndexMigrator. Exercises
# the full asynchronous create / update / drop lifecycle against the
# mongodb-atlas-local Docker container.
#
# Requires the Atlas Local container running:
#   docker-compose -f scripts/docker/docker-compose.atlas.yml up -d
#
# Each test uses a unique index name (suffixed with a per-run digest)
# so the suite is safe to re-run without manual cleanup, and tests
# don't collide with the seeded "default" index from atlas-init.js.
#
# ---------------------------------------------------------------------------
# KNOWN FLAKINESS: mongodb-atlas-local on Apple Silicon (ARM64 macOS).
# ---------------------------------------------------------------------------
# The `mongodb/mongodb-atlas-local:8.0` image runs `mongod` + `mongot` (the
# Lucene-based Atlas Search engine) under an internal supervisor. When mongot
# returns errCode 125 ("Error connecting to Search Index Management service")
# — which happens under sustained index-mutation load on the ARM64 build —
# the supervisor sends SIGTERM to mongod to flush state, then restarts both
# processes. Symptom: 5-10 second outage window mid-test, and the test
# raising Mongo::Error::NoServerAvailable.
#
# Mitigations IN PLACE:
#   - `atlas_available?` probe uses 15s server-selection timeout and up to
#     3 attempts with 5s sleep between, so a single restart window doesn't
#     skip the whole file (see below).
#   - `Parse::AtlasSearch::IndexManager.wait_for_ready` tolerates transient
#     errors via a sliding-window counter (see `transient_poll_error?`),
#     bailing out cleanly after ~25s of consecutive failures rather than
#     looping until the per-test timeout.
#
# Practical guidance:
#   - When Atlas Local is healthy: 19-20s end-to-end, 12/12 pass.
#   - When mongot is in restart cycles: file may produce errors. Re-running
#     after a fresh `docker-compose down -v && up -d` usually succeeds.
#   - On x86_64 or in CI where Docker has more memory headroom, the
#     mongot crash pattern is rare.
#   - This is environmental, not a bug in the SDK. The mongot stability
#     story on ARM64 is outside our control.
class AtlasSearchMutationsIntegrationTest < Minitest::Test
  ATLAS_URI = ENV["ATLAS_URI"] || "mongodb://localhost:29020/parse_atlas_test?directConnection=true"
  # Writer URI must be string-distinct from the reader URI per
  # `configure_writer`'s operator-safety check. Same connection, different
  # appName so the Mongo driver opens a separate client.
  WRITER_URI = ATLAS_URI + (ATLAS_URI.include?("?") ? "&" : "?") + "appName=parse-stack-search-writer"

  # Per-run nonce so concurrent / repeated runs don't collide on index
  # names. Atlas builds are slow; a leftover from a crashed run would
  # otherwise need manual cleanup.
  NONCE = SecureRandom.hex(3)

  # Single-shot build polling deadline. Atlas Local typically reaches
  # READY in 3-10 seconds for a simple index; 120s is the conservative
  # ceiling for the CI / cold-start case.
  BUILD_TIMEOUT = (ENV["ATLAS_BUILD_TIMEOUT"] || "120").to_i

  def setup
    unless self.class.atlas_available?
      skip "Atlas Search not reachable at #{ATLAS_URI}. Start it with " \
           "`docker-compose -f scripts/docker/docker-compose.atlas.yml up -d` " \
           "or override ATLAS_URI."
    end
    Parse::MongoDB.reset!
    Parse::MongoDB.configure(uri: ATLAS_URI, enabled: true, verify_role: false)
    Parse::MongoDB.configure_writer(uri: WRITER_URI, enabled: true, verify_role: false)
    Parse::MongoDB.index_mutations_enabled = true
    ENV[Parse::MongoDB::MUTATION_ENV_KEY] = "1"
    Parse::AtlasSearch::IndexManager.clear_cache
    @created = []  # track index names this test creates so teardown can drop
  end

  def teardown
    # Best-effort cleanup of any indexes this test created. Atlas tolerates
    # dropping an index that doesn't exist (no error), so the guard against
    # double-teardown is cheap.
    (@created || []).each do |name|
      Parse::MongoDB.drop_search_index("Song", name, confirm: "drop_search:Song:#{name}") rescue nil
    end
    Parse::AtlasSearch::IndexManager.clear_cache
    Parse::MongoDB.reset!
    ENV.delete(Parse::MongoDB::MUTATION_ENV_KEY)
  end

  # ---- helpers -----------------------------------------------------------

  def unique_index_name(label)
    "ix_#{label}_#{NONCE}_#{Time.now.to_i}"
  end

  def track(name)
    @created << name
    name
  end

  # ---- write primitive lifecycle ----------------------------------------

  def test_create_search_index_returns_created_then_exists_on_redeclare
    name = track(unique_index_name("create_redeclare"))
    first  = Parse::MongoDB.create_search_index("Song", name, { mappings: { dynamic: true } })
    assert_equal :created, first
    # Cache will currently report BUILDING; force refresh to confirm
    # Atlas registered the index name.
    indexes = Parse::AtlasSearch::IndexManager.list_indexes("Song", force_refresh: true)
    assert indexes.any? { |i| i["name"] == name },
           "atlas must register the newly-created index under its declared name"

    second = Parse::MongoDB.create_search_index("Song", name, { mappings: { dynamic: true } })
    assert_equal :exists, second, "duplicate-name create must short-circuit with :exists"
  end

  def test_drop_search_index_returns_dropped_then_absent
    name = track(unique_index_name("drop_absent"))
    Parse::MongoDB.create_search_index("Song", name, { mappings: { dynamic: true } })

    first  = Parse::MongoDB.drop_search_index("Song", name, confirm: "drop_search:Song:#{name}")
    assert_equal :dropped, first

    second = Parse::MongoDB.drop_search_index("Song", name, confirm: "drop_search:Song:#{name}")
    assert_equal :absent, second, "second drop must be :absent (idempotent)"
    # No longer tracked — already dropped.
    @created.delete(name)
  end

  def test_drop_search_index_refuses_regular_index_drop_token
    name = track(unique_index_name("token_replay"))
    Parse::MongoDB.create_search_index("Song", name, { mappings: { dynamic: true } })

    # Token without the "drop_search:" prefix must be rejected. This
    # prevents a token meant for `Parse::MongoDB.drop_index` (regular
    # mongo index) from being replayed against `drop_search_index`.
    assert_raises(ArgumentError) do
      Parse::MongoDB.drop_search_index("Song", name, confirm: "drop:Song:#{name}")
    end
  end

  # ---- wait_for_ready end-to-end ----------------------------------------

  def test_create_then_wait_for_ready_transitions_to_ready
    name = track(unique_index_name("wait_for_ready"))
    Parse::MongoDB.create_search_index("Song", name, { mappings: { dynamic: true } })

    outcome = Parse::AtlasSearch::IndexManager.wait_for_ready(
      "Song", name, timeout: BUILD_TIMEOUT, interval: 2,
    )
    assert_equal :ready, outcome, "wait_for_ready must return :ready within #{BUILD_TIMEOUT}s"

    assert Parse::AtlasSearch::IndexManager.index_ready?("Song", name),
           "index_ready? must agree after wait_for_ready returns :ready"
  end

  def test_wait_for_ready_returns_timeout_on_zero_timeout_when_still_building
    name = track(unique_index_name("wait_timeout"))
    Parse::MongoDB.create_search_index("Song", name, { mappings: { dynamic: true } })
    # timeout: 0 means "check once and give up if not yet READY". A fresh
    # build is almost always BUILDING for at least one round-trip.
    outcome = Parse::AtlasSearch::IndexManager.wait_for_ready(
      "Song", name, timeout: 0, interval: 0,
    )
    # Could be :ready on a very fast Atlas (unlikely sub-second), but
    # the most common reading is :timeout. Accept either rather than
    # making the test flaky.
    assert_includes [:ready, :timeout], outcome,
                    "wait_for_ready with timeout: 0 should return :timeout (or :ready on a very fast atlas)"
  end

  # ---- update primitive --------------------------------------------------

  def test_update_search_index_replaces_definition
    name = track(unique_index_name("update_def"))
    Parse::MongoDB.create_search_index("Song", name, { mappings: { dynamic: true } })
    Parse::AtlasSearch::IndexManager.wait_for_ready("Song", name, timeout: BUILD_TIMEOUT, interval: 2)

    new_def = { mappings: { dynamic: false, fields: { title: { type: "string" } } } }
    result = Parse::MongoDB.update_search_index("Song", name, new_def)
    assert_equal :updated, result

    # Atlas may report the new definition under :latestDefinition while
    # rebuilding. Poll for it explicitly — wait_for_ready on its own
    # only guarantees `queryable == true`, not that latestDefinition has
    # transitioned to the new mapping.
    deadline = Time.now + BUILD_TIMEOUT
    until Time.now > deadline
      idx = Parse::AtlasSearch::IndexManager.list_indexes("Song", force_refresh: true)
                                            .find { |i| i["name"] == name }
      latest = idx && (idx["latestDefinition"] || {})
      mappings = latest && latest["mappings"]
      break if mappings && mappings["dynamic"] == false
      sleep 2
    end
    final = Parse::AtlasSearch::IndexManager.list_indexes("Song", force_refresh: true)
                                            .find { |i| i["name"] == name }
    refute_nil final, "index must still exist after update"
    latest_def = final["latestDefinition"]
    refute_nil latest_def, "atlas must return latestDefinition after update"
    assert_equal false, latest_def["mappings"]["dynamic"],
                 "atlas latestDefinition must reflect the updated mapping; got #{latest_def.inspect}"
  end

  def test_update_search_index_raises_when_index_missing
    name = unique_index_name("update_missing")  # NOT tracked — never created
    assert_raises(ArgumentError) do
      Parse::MongoDB.update_search_index("Song", name, { mappings: { dynamic: true } })
    end
  end

  # ---- IndexManager wrappers (cache invalidation) -----------------------

  def test_index_manager_create_index_clears_cache_after_mutation
    name = track(unique_index_name("cache_clear"))
    # Prime the cache with the pre-mutation state (no `name` present).
    Parse::AtlasSearch::IndexManager.list_indexes("Song")
    Parse::AtlasSearch::IndexManager.create_index("Song", name, { mappings: { dynamic: true } })
    # Cache must be cleared — a fresh non-force read should now see the
    # newly-submitted index (Atlas registers the name immediately even
    # though `queryable` flips later).
    indexes = Parse::AtlasSearch::IndexManager.list_indexes("Song")
    assert indexes.any? { |i| i["name"] == name },
           "IndexManager.create_index must invalidate the cache so subsequent reads see the new index"
  end

  # ---- DSL + Migrator end-to-end ----------------------------------------

  # Anonymous model class wired specifically for this test. Avoid letting
  # the class linger across test methods by using setup/teardown helpers.
  def build_model_class(class_name, &block)
    klass = Class.new(Parse::Object, &block)
    klass.define_singleton_method(:name) { class_name }
    klass.parse_class(class_name)
    klass
  end

  def test_migrator_plan_classifies_to_create_against_real_atlas
    ix_name = track(unique_index_name("migrator_create"))
    klass = build_model_class("Song") do
      # Re-open Song just for declaration storage; Song is the seeded
      # collection on the docker init and stays as the real parse_class.
    end
    klass.mongo_search_index(ix_name, { mappings: { dynamic: true } })

    plan = Parse::Schema::SearchIndexMigrator.new(klass).plan
    assert plan[:atlas_available], "atlas must be reachable for this test"
    assert plan[:to_create].any? { |d| d[:name] == ix_name },
           "newly-declared index must appear in :to_create against real atlas"
    refute plan[:in_sync].any? { |d| d[:name] == ix_name }
  end

  def test_migrator_apply_creates_then_plan_shows_in_sync
    ix_name = track(unique_index_name("migrator_apply"))
    klass = build_model_class("Song") {}
    klass.mongo_search_index(ix_name, { mappings: { dynamic: true } })

    r = Parse::Schema::SearchIndexMigrator.new(klass).apply!(wait: true, timeout: BUILD_TIMEOUT)
    assert_equal 1, r[:created].size
    assert_equal ix_name, r[:created].first[:name]
    assert_equal :ready, r[:wait_results][ix_name],
                 "wait: true must surface the per-index readiness outcome"

    # Re-plan — same declaration must now classify as in_sync, not to_create.
    Parse::AtlasSearch::IndexManager.clear_cache("Song")
    plan2 = Parse::Schema::SearchIndexMigrator.new(klass).plan
    assert plan2[:in_sync].any? { |d| d[:name] == ix_name },
           "after apply + wait_for_ready, the index must be classified in_sync"
    refute plan2[:to_create].any? { |d| d[:name] == ix_name }
  end

  def test_migrator_detects_drift_when_declared_definition_diverges
    ix_name = track(unique_index_name("migrator_drift"))
    klass = build_model_class("Song") {}
    klass.mongo_search_index(ix_name, { mappings: { dynamic: true } })
    Parse::Schema::SearchIndexMigrator.new(klass).apply!(wait: true, timeout: BUILD_TIMEOUT)

    # Now declare a model class with a DIFFERENT definition for the same
    # name. The previous class can't be redeclared (DSL raises on
    # different content), so build a fresh model class for the drift check.
    drifted_klass = build_model_class("Song") {}
    drifted_klass.mongo_search_index(
      ix_name,
      { mappings: { dynamic: false, fields: { title: { type: "string" } } } },
    )
    plan = Parse::Schema::SearchIndexMigrator.new(drifted_klass).plan
    drifted_names = plan[:drifted].map { |e| e[:declared][:name] }
    assert_includes drifted_names, ix_name,
                    "definition divergence must surface in :drifted"
    # And NOT in :in_sync.
    refute plan[:in_sync].any? { |d| d[:name] == ix_name }
  end

  def test_migrator_applies_update_with_explicit_opt_in
    ix_name = track(unique_index_name("migrator_update"))
    klass = build_model_class("Song") {}
    klass.mongo_search_index(ix_name, { mappings: { dynamic: true } })
    Parse::Schema::SearchIndexMigrator.new(klass).apply!(wait: true, timeout: BUILD_TIMEOUT)

    drifted_klass = build_model_class("Song") {}
    drifted_klass.mongo_search_index(
      ix_name,
      { mappings: { dynamic: false, fields: { title: { type: "string" } } } },
    )
    # Default apply! must NOT update.
    r1 = Parse::Schema::SearchIndexMigrator.new(drifted_klass).apply!
    assert_includes r1[:drifted_skipped], ix_name
    assert_empty r1[:updated]
    # Explicit update: true rebuilds.
    r2 = Parse::Schema::SearchIndexMigrator.new(drifted_klass).apply!(update: true)
    assert_includes r2[:updated], ix_name
  end

  # ---- atlas availability probe -----------------------------------------

  # Probe with retry-and-backoff. mongodb-atlas-local's internal supervisor
  # cycles mongod on replica-set sync events (5-10s outage windows); a
  # single short-timeout probe lands in the window often enough to skip
  # the whole suite. 15s server-selection × up to 3 attempts × 5s sleep
  # covers a single restart cycle reliably.
  def self.atlas_available?
    return @atlas_available if defined?(@atlas_available)
    @atlas_available = probe_atlas_with_retries
  end

  def self.probe_atlas_with_retries(attempts: 3, sleep_between: 5)
    require "mongo"
    last_error = nil
    attempts.times do |i|
      begin
        client = Mongo::Client.new(
          ATLAS_URI,
          server_selection_timeout: 15,
          connect_timeout: 5,
          socket_timeout: 10,
          logger: Logger.new(IO::NULL),
        )
        client.database["Song"].aggregate([{ "$listSearchIndexes" => {} }]).first
        client.close
        return true
      rescue => e
        last_error = e
        client&.close rescue nil
        sleep sleep_between if i < attempts - 1
      end
    end
    warn "[AtlasSearchMutationsIntegrationTest] Atlas probe failed at #{ATLAS_URI} " \
         "after #{attempts} attempts: #{last_error.class}: #{last_error.message}"
    false
  end
end
