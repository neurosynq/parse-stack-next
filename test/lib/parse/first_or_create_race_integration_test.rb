require_relative "../../test_helper_integration"

# Integration tests for the synchronize-create lock on
# Parse::Object.first_or_create! and Parse::Object.create_or_update!.
#
# These exercise the in-process Mutex fallback path (no Redis container is
# wired into scripts/docker/docker-compose.test.yml today). The unit tests in
# test/lib/parse/create_lock_test.rb cover cross-process semantics via a fake
# Redis-like Moneta store; cross-dyno behavior with a real Redis is the
# operator's environment to validate.
#
# What we verify here, against a real Parse Server:
# - Concurrent threads with synchronize: true cannot create duplicate rows
#   for the same query_attrs.
# - The legacy (synchronize: false / default) path remains unchanged.
# - Code 137 (DuplicateValue) is rescued inside the lock when triggered by a
#   pre-seeded row (simulates a MongoDB unique-index race).
# - `synchronize: false` overrides a true class default (escape hatch).

class FocRaceTestUser < Parse::Object
  parse_class "FocRaceTestUser"

  property :email, :string
  property :name, :string
  property :tag, :string
end

class FocRaceTestOrder < Parse::Object
  parse_class "FocRaceTestOrder"

  property :reference, :string
  property :status, :string
  property :amount, :integer
end

# Declares the correctness-floor index through the `unique_index_on` DSL
# (vs. the raw-driver `ensure_unique_index!` helper used by the other 137
# tests). Used to prove the DSL → `apply_indexes!` path provisions a working
# floor end to end.
class FocRaceDslUser < Parse::Object
  parse_class "FocRaceDslUser"

  property :email, :string
  property :name, :string

  unique_index_on :email
end

class FirstOrCreateRaceTest < Minitest::Test
  include ParseStackIntegrationTest

  THREAD_COUNT = 12

  def with_timeout(seconds, message = "Operation")
    Timeout::timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{message} timed out after #{seconds} seconds"
  end

  def setup
    super
    @saved_default = Parse.synchronize_create_default
    @saved_options = Parse.synchronize_create_options
    @saved_classes = Parse.synchronize_classes
    Parse.synchronize_create_default = false
    Parse.synchronize_create_options = {}
    Parse.synchronize_classes = nil
    Parse::CreateLock.reset!
  end

  def teardown
    Parse.synchronize_create_default = @saved_default
    Parse.synchronize_create_options = @saved_options
    Parse.synchronize_classes = @saved_classes
    FocRaceTestUser.synchronize_create_default = nil if FocRaceTestUser.respond_to?(:synchronize_create_default=)
    FocRaceTestOrder.synchronize_create_default = nil if FocRaceTestOrder.respond_to?(:synchronize_create_default=)
    super
  end

  def test_concurrent_first_or_create_with_synchronize_dedupes
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(30, "synchronize concurrent first_or_create!") do
        email = "race-#{SecureRandom.hex(4)}@example.com"
        barrier = Queue.new

        threads = THREAD_COUNT.times.map do |i|
          Thread.new do
            barrier.pop  # wait for green light
            begin
              FocRaceTestUser.first_or_create!(
                { email: email },
                { name: "Racer #{i}" },
                synchronize: true,
              )
            rescue => e
              e
            end
          end
        end

        # Release all threads at once
        THREAD_COUNT.times { barrier.push(:go) }
        results = threads.map(&:value)

        errors = results.select { |r| r.is_a?(Exception) }
        assert_empty errors, "expected all threads to succeed, got: #{errors.map(&:message).inspect}"

        ids = results.map(&:id).compact.uniq
        assert_equal 1, ids.size, "expected one objectId across #{THREAD_COUNT} concurrent callers, got #{ids.inspect}"

        rows = FocRaceTestUser.query(email: email).results
        assert_equal 1, rows.size, "expected exactly one row in Parse for #{email}, got #{rows.size}"
      end
    end
  end

  def test_unsynchronized_path_unchanged
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "unsynchronized first_or_create!") do
        email = "unsync-#{SecureRandom.hex(4)}@example.com"
        u = FocRaceTestUser.first_or_create!({ email: email }, { name: "U1" })
        refute_nil u.id
        refute u.new?

        u2 = FocRaceTestUser.first_or_create!({ email: email }, { name: "Different Name" })
        assert_equal u.id, u2.id, "second call should find the same row"
      end
    end
  end

  def test_per_call_synchronize_false_overrides_class_default
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "synchronize: false escape hatch") do
        FocRaceTestUser.synchronize_create_default = true
        email = "escape-#{SecureRandom.hex(4)}@example.com"

        # synchronize: false short-circuits the lock and runs the legacy path
        u = FocRaceTestUser.first_or_create!(
          { email: email },
          { name: "Escape" },
          synchronize: false,
        )
        refute_nil u.id
      end
    end
  end

  def test_create_or_update_synchronize_concurrent_safety
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(30, "synchronize concurrent create_or_update!") do
        reference = "REF-#{SecureRandom.hex(4)}"
        barrier = Queue.new

        threads = THREAD_COUNT.times.map do |i|
          Thread.new do
            barrier.pop
            begin
              FocRaceTestOrder.create_or_update!(
                { reference: reference },
                { status: "open", amount: i },
                synchronize: true,
              )
            rescue => e
              e
            end
          end
        end

        THREAD_COUNT.times { barrier.push(:go) }
        results = threads.map(&:value)
        errors = results.select { |r| r.is_a?(Exception) }
        assert_empty errors, errors.map(&:message).inspect

        ids = results.map(&:id).compact.uniq
        assert_equal 1, ids.size, "expected single objectId across concurrent create_or_update!"

        rows = FocRaceTestOrder.query(reference: reference).results
        assert_equal 1, rows.size
      end
    end
  end

  def test_global_default_applies_when_class_inherits
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(30, "global default synchronize") do
        Parse.synchronize_create_default = true
        email = "global-#{SecureRandom.hex(4)}@example.com"
        barrier = Queue.new

        threads = THREAD_COUNT.times.map do |i|
          Thread.new do
            barrier.pop
            FocRaceTestUser.first_or_create!({ email: email }, { name: "G#{i}" })
          end
        end

        THREAD_COUNT.times { barrier.push(:go) }
        threads.each(&:join)

        rows = FocRaceTestUser.query(email: email).results
        assert_equal 1, rows.size, "global default should serialize all callers"
      end
    end
  end

  def test_synchronize_classes_allowlist_blocks_non_allowed
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      Parse.synchronize_classes = [FocRaceTestUser]
      err = assert_raises(Parse::CreateLockUnavailableError) do
        FocRaceTestOrder.first_or_create!({ reference: "X" }, {}, synchronize: true)
      end
      assert_match(/synchronize_classes allowlist/, err.message)
    end
  end

  # Verifies that when an operator has provisioned a MongoDB unique index on
  # the dedup tuple (the correctness floor for `first_or_create!` race
  # protection), a duplicate insert surfaces as Parse code 137 (DuplicateValue)
  # and the response is retained on the object's @_last_response. This is the
  # plumbing the synchronize-wrapper relies on to rescue and re-query when a
  # cross-process race slips past the lock.
  def test_mongo_unique_index_surfaces_code_137_on_object
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Parse::MongoDB must be enabled to provision indexes" unless mongodb_writable?

    with_parse_server do
      with_timeout(15, "mongo 137 plumbing") do
        collection_name = FocRaceTestUser.parse_class
        index_name = "foc_race_email_unique_#{SecureRandom.hex(2)}"
        ensure_unique_index!(collection_name, { email: 1 }, name: index_name)

        begin
          email = "idx-137-#{SecureRandom.hex(4)}@example.com"
          first = FocRaceTestUser.create!(email: email, name: "First")
          refute_nil first.id

          # Build a second object with the same email and try to save. The
          # Mongo unique index rejects it; Parse Server surfaces code 137,
          # and the SDK retains the response on @_last_response so the
          # synchronize wrapper can inspect it.
          second = FocRaceTestUser.new(email: email, name: "Second")
          err = assert_raises(Parse::RecordNotSaved) { second.save! }

          last_response = err.object.instance_variable_get(:@_last_response)
          refute_nil last_response, "expected @_last_response to be retained on duplicate-key failure"
          assert_respond_to last_response, :code
          assert_equal Parse::Client::DuplicateValueError::CODE, last_response.code,
                       "expected Parse code 137 (DuplicateValue), got #{last_response.code}: #{last_response.error rescue nil}"
        ensure
          drop_index!(collection_name, index_name)
        end
      end
    end
  end

  # Race test with a Mongo unique index in place AND the synchronize lock on.
  # Both layers active: lock dedupes concurrent attempts; if the lock is ever
  # bypassed (TTL expiry, cross-process secret mismatch, etc.) the index
  # catches it and the synchronize wrapper rescues code 137 and re-queries.
  # Net invariant under any race: exactly one row, all callers see the same id.
  def test_concurrent_synchronize_with_mongo_unique_index
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Parse::MongoDB must be enabled to provision indexes" unless mongodb_writable?

    with_parse_server do
      with_timeout(45, "synchronize + mongo unique index race") do
        collection_name = FocRaceTestUser.parse_class
        index_name = "foc_race_email_unique_#{SecureRandom.hex(2)}"
        ensure_unique_index!(collection_name, { email: 1 }, name: index_name)

        begin
          email = "idx-race-#{SecureRandom.hex(4)}@example.com"
          barrier = Queue.new

          threads = THREAD_COUNT.times.map do |i|
            Thread.new do
              barrier.pop
              begin
                FocRaceTestUser.first_or_create!(
                  { email: email },
                  { name: "R#{i}" },
                  synchronize: true,
                )
              rescue => e
                e
              end
            end
          end

          THREAD_COUNT.times { barrier.push(:go) }
          results = threads.map(&:value)

          errors = results.select { |r| r.is_a?(Exception) }
          assert_empty errors, "expected every caller to receive the winner row, got: #{errors.map { |e| "#{e.class}: #{e.message}" }.inspect}"

          ids = results.map(&:id).compact.uniq
          assert_equal 1, ids.size, "expected single objectId across #{THREAD_COUNT} concurrent callers"

          rows = FocRaceTestUser.query(email: email).results
          assert_equal 1, rows.size, "Mongo unique index ensures exactly one row regardless of race outcome"
        ensure
          drop_index!(collection_name, index_name)
        end
      end
    end
  end

  # Provisions the unique index through the `unique_index_on` DSL and its
  # `apply_indexes!` writer path (the triple-gated mutation route), NOT the
  # raw driver — then runs the concurrent race and asserts the net invariant.
  # This is the end-to-end proof that the DSL produces a working correctness
  # floor: lock dedupes the common path, and the DSL-provisioned index forces
  # a single row even if the lock is bypassed.
  def test_unique_index_on_dsl_provisions_floor_and_dedupes_race
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    # Self-configure the Mongo reader + writer (mongo gem + reachable
    # localhost:29017) so this floor test RUNS rather than skipping. Unlike the
    # two raw-driver 137 tests above — which gate on ambient `mongodb_writable?`
    # config and skip when none is present — the DSL apply path is the point of
    # this test, so it must be continuously verified, not silently skipped.
    skip "Mongo unavailable for DSL apply path (need mongo gem + localhost:29017)" unless setup_dsl_floor_mongo!

    with_parse_server do
      with_timeout(45, "unique_index_on DSL floor race") do
        collection_name = FocRaceDslUser.parse_class
        begin
          result = FocRaceDslUser.apply_indexes![collection_name]
          refute_nil result, "apply_indexes! must return a result for the parent collection"
          assert_operator (result[:created].size + result[:skipped_exists].size), :>=, 1,
                          "apply_indexes! must create or confirm the unique_index_on declaration"

          raw = Parse::MongoDB.indexes(collection_name)
          email_idx = raw.find { |i| (i["key"] || i[:key]) == { "email" => 1 } }
          refute_nil email_idx, "unique_index_on :email must land { email: 1 } on the collection"
          assert_equal true, email_idx["unique"], "the DSL-provisioned index must be unique"

          email = "dsl-floor-#{SecureRandom.hex(4)}@example.com"
          barrier = Queue.new
          threads = THREAD_COUNT.times.map do |i|
            Thread.new do
              barrier.pop
              begin
                FocRaceDslUser.first_or_create!({ email: email }, { name: "D#{i}" }, synchronize: true)
              rescue => e
                e
              end
            end
          end

          THREAD_COUNT.times { barrier.push(:go) }
          results = threads.map(&:value)

          errors = results.select { |r| r.is_a?(Exception) }
          assert_empty errors, "every caller must receive the winner row, got: #{errors.map { |e| "#{e.class}: #{e.message}" }.inspect}"

          ids = results.map(&:id).compact.uniq
          assert_equal 1, ids.size, "DSL-provisioned unique index must force a single objectId across #{THREAD_COUNT} callers"

          rows = FocRaceDslUser.query(email: email).results
          assert_equal 1, rows.size, "exactly one row despite the race"
        ensure
          drop_index_by_key!(collection_name, { "email" => 1 })
          teardown_dsl_floor_mongo!
        end
      end
    end
  end

  private

  # Reader + writer URIs match the docker-compose mapping and the db Parse
  # Server itself uses (`/parse`), so a DSL-provisioned index lands on the same
  # collection Parse Server writes to and the unique constraint actually
  # engages. The writer URI is string-distinct (distinct appName) to satisfy
  # configure_writer's operator-safety check; verify_role: false because the
  # docker test user holds admin (production must run verify_role: true).
  DSL_MONGO_URI  = (ENV["PARSE_TEST_MONGO_URI"] || "mongodb://admin:password@localhost:29017/parse_stack_next_it?authSource=admin")
  DSL_WRITER_URI = DSL_MONGO_URI + "&appName=parse-stack-foc-dsl-writer"

  # Self-contained reader+writer config + mutation triple-gate (mirrors
  # mongodb_indexes_integration_test's setup_mongodb_full!). Returns false to
  # skip when the mongo gem or server isn't available.
  def setup_dsl_floor_mongo!
    require "mongo"
    require "parse/mongodb"
    Parse::MongoDB.reset!
    Parse::MongoDB.configure(uri: DSL_MONGO_URI, enabled: true, verify_role: false)
    Parse::MongoDB.configure_writer(uri: DSL_WRITER_URI, enabled: true, verify_role: false)
    Parse::MongoDB.index_mutations_enabled = true
    ENV[Parse::MongoDB::MUTATION_ENV_KEY] = "1"
    # Prove the server is actually reachable before claiming the test can run,
    # so an unreachable Mongo skips cleanly instead of failing mid-test.
    Parse::MongoDB.indexes("FocRaceDslUser")
    true
  rescue LoadError, StandardError => e
    puts "Skipping DSL floor mongo setup: #{e.class}: #{e.message}"
    false
  end

  # Closes the mutation gate and resets Parse::MongoDB so the global state is
  # restored for the rest of the suite (the raw-driver 137 siblings continue to
  # gate on their own `mongodb_writable?` check and are unaffected).
  def teardown_dsl_floor_mongo!
    return unless defined?(Parse::MongoDB)
    Parse::MongoDB.index_mutations_enabled = false
    ENV.delete(Parse::MongoDB::MUTATION_ENV_KEY)
    Parse::MongoDB.reset!
  rescue StandardError
    # best-effort
  end

  # Drop an index identified by key signature (the DSL auto-names indexes, so
  # we can't drop by a name we chose). Best-effort cleanup.
  def drop_index_by_key!(collection_name, key)
    Parse::MongoDB.collection(collection_name).indexes.each do |idx|
      next unless (idx["key"] || idx[:key]) == key
      name = idx["name"] || idx[:name]
      Parse::MongoDB.collection(collection_name).indexes.drop_one(name)
    end
  rescue StandardError
    # best-effort cleanup; tests reset the DB between runs anyway
  end

  def mongodb_writable?
    return false unless defined?(Parse::MongoDB)
    return false unless Parse::MongoDB.respond_to?(:enabled?) && Parse::MongoDB.enabled?
    # If MongoDB read-only enforcement is on, index creation will fail; skip.
    !(Parse::MongoDB.respond_to?(:read_only?) && Parse::MongoDB.read_only? == true)
  rescue StandardError
    false
  end

  def ensure_unique_index!(collection_name, keys, name:)
    Parse::MongoDB.collection(collection_name).indexes.create_one(keys, unique: true, name: name)
  end

  def drop_index!(collection_name, name)
    Parse::MongoDB.collection(collection_name).indexes.drop_one(name)
  rescue StandardError
    # best-effort cleanup; tests reset the DB between runs anyway
  end
end
