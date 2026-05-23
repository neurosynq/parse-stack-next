# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper_integration"
require "timeout"

# Test models for index migration integration testing
class IxIntegCar < Parse::Object
  parse_class "IxIntegCar"
  property :make, :string
  property :model, :string
  property :year, :integer
  property :vin, :string
  property :tags, :array
  property :location, :geopoint
  belongs_to :owner, as: :user

  mongo_index :make, :model, :year
  mongo_index :vin, unique: true
  mongo_index :owner
  mongo_geo_index :location
  mongo_index :tags
end

class IxIntegBare < Parse::Object
  parse_class "IxIntegBare"
  property :slug, :string
  # No mongo_index — verifies migrator handles classes that haven't
  # adopted the DSL.
end

class IxIntegRoleParent < Parse::Object
  parse_class "IxIntegRoleParent"
  property :name, :string
  has_many :members, through: :relation, as: :ix_integ_car
  mongo_relation_index :members, bidirectional: true
end

# Exercises the parse_reference auto-index registration path.
class IxIntegRefAuto < Parse::Object
  parse_class "IxIntegRefAuto"
  property :title, :string
  parse_reference  # auto-registers unique+sparse index on parseReference
end

# Integration test for Parse::Core::Indexing + Parse::Schema::IndexMigrator
# + Parse::MongoDB writer primitives against a real MongoDB instance.
#
# Configures both reader and writer against the docker-compose Mongo
# (the test mongo user has admin role, which the writer-role check would
# normally reject — `verify_role: false` is passed for the test setup
# only; production deployments must run with `verify_role: true`).
class MongoDBIndexesIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  # Reader URI matches the docker-compose mapping.
  MONGODB_URI = "mongodb://admin:password@localhost:27019/parse?authSource=admin"
  # Writer URI must be string-distinct from the reader (operator-safety
  # check in `configure_writer`). Same target connection, different
  # appName so the Mongo driver opens an independent client.
  WRITER_URI  = MONGODB_URI + "&appName=parse-stack-writer-tests"

  def setup_mongodb_full!
    require "mongo"
    require "parse/mongodb"
    Parse::MongoDB.reset!
    Parse::MongoDB.configure(uri: MONGODB_URI, enabled: true, verify_role: false)
    Parse::MongoDB.configure_writer(uri: WRITER_URI, enabled: true, verify_role: false)
    Parse::MongoDB.index_mutations_enabled = true
    ENV[Parse::MongoDB::MUTATION_ENV_KEY] = "1"
    true
  rescue LoadError, StandardError => e
    puts "Skipping index integration tests: #{e.class}: #{e.message}"
    false
  end

  def teardown_mongodb_full!
    return unless defined?(Parse::MongoDB)
    # Drop every non-_id_ index we created so the next test starts clean.
    %w[IxIntegCar IxIntegBare IxIntegRoleParent _Join:members:IxIntegRoleParent IxIntegRefAuto].each do |coll|
      next unless Parse::MongoDB.respond_to?(:enabled?) && Parse::MongoDB.enabled?
      begin
        existing = Parse::MongoDB.indexes(coll)
        existing.each do |idx|
          name = idx["name"] || idx[:name]
          next if name == "_id_"
          # Bypass the confirm guard via the driver directly (test cleanup
          # is operator-trusted; the application gate already proved out
          # in the per-method tests).
          Parse::MongoDB.collection(coll).indexes.drop_one(name) rescue nil
        end
      rescue StandardError
        # Collection may not exist yet — fine.
      end
    end
    Parse::MongoDB.index_mutations_enabled = false
    ENV.delete(Parse::MongoDB::MUTATION_ENV_KEY)
    Parse::MongoDB.reset!
  end

  def docker_required
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
  end

  # ---- plan against real Mongo ---------------------------------------------

  def test_plan_against_empty_collection_lists_all_declarations_to_create
    docker_required
    skip "mongo unavailable" unless setup_mongodb_full!
    begin
      # Empty collection — only the implicit _id_ index exists.
      plans = IxIntegCar.indexes_plan
      p = plans["IxIntegCar"]
      refute_nil p, "parent collection plan must be present"
      assert_includes p[:parse_managed], "_id_"
      assert_equal 5, p[:to_create].size, "all 5 declarations must need creation on an empty collection"
      assert_equal 0, p[:in_sync].size
      assert_empty p[:orphans]
      assert p[:capacity_ok]
    ensure
      teardown_mongodb_full!
    end
  end

  def test_apply_creates_declared_indexes_on_real_collection
    docker_required
    skip "mongo unavailable" unless setup_mongodb_full!
    begin
      results = IxIntegCar.apply_indexes!
      result  = results["IxIntegCar"]
      assert_equal 5, result[:created].size, "all 5 declared indexes should be created"
      assert_empty result[:conflicts]
      refute result[:capacity_blocked]

      # Confirm they actually landed on the server.
      raw = Parse::MongoDB.indexes("IxIntegCar")
      names = raw.map { |i| i["name"] || i[:name] }
      assert_includes names, "_id_"
      # Auto-generated names: field_dir joined.
      assert(raw.any? { |i| (i["key"] || i[:key]) == { "make" => 1, "model" => 1, "year" => 1 } })
      assert(raw.any? { |i| (i["key"] || i[:key]) == { "vin" => 1 } && i["unique"] == true })
      assert(raw.any? { |i| (i["key"] || i[:key]) == { "_p_owner" => 1 } })
      assert(raw.any? { |i| (i["key"] || i[:key]) == { "location" => "2dsphere" } })
      assert(raw.any? { |i| (i["key"] || i[:key]) == { "tags" => 1 } })
    ensure
      teardown_mongodb_full!
    end
  end

  def test_apply_is_idempotent_second_run_creates_nothing
    docker_required
    skip "mongo unavailable" unless setup_mongodb_full!
    begin
      first  = IxIntegCar.apply_indexes!["IxIntegCar"]
      second = IxIntegCar.apply_indexes!["IxIntegCar"]
      assert_equal 5, first[:created].size
      assert_equal 0, second[:created].size, "second apply must create nothing"
      assert_equal 5, second[:skipped_exists].size, "second apply must report 5 already-existing"
    ensure
      teardown_mongodb_full!
    end
  end

  def test_drop_orphans_off_by_default
    docker_required
    skip "mongo unavailable" unless setup_mongodb_full!
    begin
      # Create an orphan index that the model does NOT declare.
      Parse::MongoDB.collection("IxIntegCar").indexes.create_one({ "nickname" => 1 }, name: "nickname_orphan")
      plan = IxIntegCar.indexes_plan["IxIntegCar"]
      assert_includes plan[:orphans], "nickname_orphan"

      result = IxIntegCar.apply_indexes!["IxIntegCar"]  # additive, drop omitted
      assert_empty result[:dropped], "apply! without drop: must NEVER drop orphans"

      raw = Parse::MongoDB.indexes("IxIntegCar")
      names = raw.map { |i| i["name"] || i[:name] }
      assert_includes names, "nickname_orphan", "orphan must still exist after additive apply!"
    ensure
      teardown_mongodb_full!
    end
  end

  def test_drop_orphans_explicit_true_drops
    docker_required
    skip "mongo unavailable" unless setup_mongodb_full!
    begin
      Parse::MongoDB.collection("IxIntegCar").indexes.create_one({ "stale" => 1 }, name: "stale_orphan")
      result = IxIntegCar.apply_indexes!(drop: true)["IxIntegCar"]
      assert_includes result[:dropped], "stale_orphan"
      names = Parse::MongoDB.indexes("IxIntegCar").map { |i| i["name"] || i[:name] }
      refute_includes names, "stale_orphan"
    ensure
      teardown_mongodb_full!
    end
  end

  def test_parse_managed_id_index_is_never_dropped
    docker_required
    skip "mongo unavailable" unless setup_mongodb_full!
    begin
      # apply with drop: true would drop unknown orphans — but `_id_`
      # must always be in parse_managed and therefore protected.
      result = IxIntegCar.apply_indexes!(drop: true)["IxIntegCar"]
      assert_empty result[:dropped] - %w[]  # nothing user-created to drop here

      names = Parse::MongoDB.indexes("IxIntegCar").map { |i| i["name"] || i[:name] }
      assert_includes names, "_id_", "_id_ must remain after a drop:true apply"
    ensure
      teardown_mongodb_full!
    end
  end

  # ---- writer primitive direct-call paths ---------------------------------

  def test_create_index_returns_exists_on_identical_redeclaration
    docker_required
    skip "mongo unavailable" unless setup_mongodb_full!
    begin
      first  = Parse::MongoDB.create_index("IxIntegBare", { slug: 1 })
      second = Parse::MongoDB.create_index("IxIntegBare", { slug: 1 })
      assert_equal :created, first
      assert_equal :exists,  second
    ensure
      teardown_mongodb_full!
    end
  end

  def test_drop_index_requires_correct_confirm_against_real_collection
    docker_required
    skip "mongo unavailable" unless setup_mongodb_full!
    begin
      Parse::MongoDB.create_index("IxIntegBare", { slug: 1 }, name: "slug_idx")
      assert_raises(ArgumentError) do
        Parse::MongoDB.drop_index("IxIntegBare", "slug_idx", confirm: "wrong")
      end
      result = Parse::MongoDB.drop_index("IxIntegBare", "slug_idx",
                                         confirm: "drop:IxIntegBare:slug_idx")
      assert_equal :dropped, result
    ensure
      teardown_mongodb_full!
    end
  end

  def test_drop_index_returns_absent_when_index_does_not_exist
    docker_required
    skip "mongo unavailable" unless setup_mongodb_full!
    begin
      result = Parse::MongoDB.drop_index("IxIntegBare", "no_such_index",
                                         confirm: "drop:IxIntegBare:no_such_index")
      assert_equal :absent, result
    ensure
      teardown_mongodb_full!
    end
  end

  # ---- relation indexes (join collection) ---------------------------------

  def test_relation_indexes_apply_creates_owning_and_related_on_join_collection
    docker_required
    skip "mongo unavailable" unless setup_mongodb_full!
    begin
      results = IxIntegRoleParent.apply_indexes!
      join_coll = "_Join:members:IxIntegRoleParent"
      result = results[join_coll]
      refute_nil result, "apply! must produce a result entry keyed on the join collection"
      assert_equal 2, result[:created].size, "bidirectional must create both owningId and relatedId indexes"

      raw = Parse::MongoDB.indexes(join_coll)
      keys = raw.map { |i| i["key"] || i[:key] }
      assert_includes keys, { "owningId" => 1 }
      assert_includes keys, { "relatedId" => 1 }
    ensure
      teardown_mongodb_full!
    end
  end

  def test_relation_index_plan_uses_join_collection_key
    docker_required
    skip "mongo unavailable" unless setup_mongodb_full!
    begin
      plans = IxIntegRoleParent.indexes_plan
      assert_includes plans.keys, "_Join:members:IxIntegRoleParent"
      p = plans["_Join:members:IxIntegRoleParent"]
      assert_equal 2, p[:to_create].size
    ensure
      teardown_mongodb_full!
    end
  end

  # ---- describe(:indexes, network: true) integration -----------------------

  def test_describe_indexes_section_includes_declared_and_drift
    docker_required
    skip "mongo unavailable" unless setup_mongodb_full!
    begin
      data = IxIntegCar.describe(:indexes, network: true)
      ix = data[:indexes]
      assert ix[:available]
      assert ix.key?(:declared)
      assert ix.key?(:drift)
      assert ix.key?(:capacity)
      assert_equal 5, ix[:declared].size
      assert_equal 5, ix[:drift][:to_create].size, "pre-apply, all declarations should be to_create"

      IxIntegCar.apply_indexes!
      data2 = IxIntegCar.describe(:indexes, network: true)
      ix2 = data2[:indexes]
      assert_equal 5, ix2[:drift][:in_sync].size, "post-apply, all declarations should be in_sync"
      assert_empty ix2[:drift][:to_create]
    ensure
      teardown_mongodb_full!
    end
  end

  # ---- $indexStats (usage counters) ---------------------------------------

  def test_index_stats_primitive_returns_real_counters
    docker_required
    skip "mongo unavailable" unless setup_mongodb_full!
    begin
      IxIntegCar.apply_indexes!
      # Issue a few queries so MongoDB has something to report on the
      # _id_ index (always exists) and ideally on others.
      3.times { Parse::MongoDB.collection("IxIntegCar").find({}).to_a }

      # `index_stats` requires explicit `master: true` (audit hardening:
      # `$indexStats` discloses cluster metadata, so it is admin-only).
      stats = Parse::MongoDB.index_stats("IxIntegCar", master: true)
      refute_empty stats, "$indexStats must return data with the admin role"
      assert stats.key?("_id_"), "stats must include the implicit _id_ index"
      assert stats["_id_"].key?(:ops)
      assert stats["_id_"].key?(:since)
      assert stats["_id_"][:ops].is_a?(Integer)
    ensure
      teardown_mongodb_full!
    end
  end

  def test_describe_indexes_usage_flag_merges_real_index_stats
    docker_required
    skip "mongo unavailable" unless setup_mongodb_full!
    begin
      IxIntegCar.apply_indexes!
      # Generate some real index usage that $indexStats can report on.
      3.times { Parse::MongoDB.collection("IxIntegCar").find({}).to_a }

      # `describe(:indexes, ..., usage: true)` forwards `master:` to
       # `Parse::MongoDB.index_stats`, which is admin-only and requires
       # the explicit opt-in. Without `master: true` the section reports
       # `usage_available: false` and counter fields are absent.
      data = IxIntegCar.describe(:indexes, network: true, usage: true, master: true)
      ix = data[:indexes]
      assert ix[:available]
      assert_equal true, ix[:usage_available],
        "admin role on the test container should always have $indexStats access"
      id_entry = ix[:indexes].find { |i| i[:name] == "_id_" }
      refute_nil id_entry
      assert id_entry.key?(:usage), "_id_ must report usage when usage: true"
      assert id_entry[:usage][:ops].is_a?(Integer)
    ensure
      teardown_mongodb_full!
    end
  end

  # ---- parse_reference auto-index ----------------------------------------

  def test_parse_reference_auto_registered_unique_sparse_index_creates_on_apply
    docker_required
    skip "mongo unavailable" unless setup_mongodb_full!
    begin
      results = IxIntegRefAuto.apply_indexes!
      result  = results["IxIntegRefAuto"]
      assert_equal 1, result[:created].size,
        "parse_reference must auto-register and apply exactly one unique-sparse index"

      raw = Parse::MongoDB.indexes("IxIntegRefAuto")
      ref_idx = raw.find { |i| (i["key"] || i[:key]) == { "parseReference" => 1 } }
      refute_nil ref_idx, "parseReference index must exist on the collection after apply"
      assert_equal true, ref_idx["unique"], "must be unique"
      assert_equal true, ref_idx["sparse"], "must be sparse so backfill workflows aren't blocked"
    ensure
      teardown_mongodb_full!
    end
  end

  # ---- rake task invocation ----------------------------------------------

  def test_rake_indexes_plan_task_prints_per_class_diff
    docker_required
    skip "mongo unavailable" unless setup_mongodb_full!
    begin
      require "rake"
    rescue LoadError
      skip "rake task tests require rake gem"
    end
    begin
      require "parse/stack/tasks"

      # Re-install tasks under a fresh Rake::Application so prior test
      # state doesn't interfere. The Parse::Stack::Tasks#install_tasks
      # method is the public install API.
      old_app = Rake.application
      Rake.application = Rake::Application.new
      task_owner = Parse::Stack::Tasks.new
      task_owner.install_tasks
      # The verify_env task tries to invoke the Rails :environment task;
      # short-circuit it by stubbing the dependency check.
      Rake::Task["parse:env"].clear_prerequisites rescue nil

      output = capture_io { Rake::Task["parse:mongo:indexes:plan"].invoke }.first
      assert_match(/IxIntegCar/, output)
      assert_match(/to_create:/, output)
    ensure
      Rake.application = old_app if defined?(old_app)
      teardown_mongodb_full!
    end
  end

  def test_rake_indexes_apply_task_refuses_without_gates
    docker_required
    skip "mongo unavailable" unless setup_mongodb_full!
    begin
      require "rake"
    rescue LoadError
      skip "rake task tests require rake gem"
    end
    begin
      require "parse/stack/tasks"

      # Configure reader+writer but DISABLE the env gate so the rake
      # task's up-front gate restatement raises.
      old_app = Rake.application
      Rake.application = Rake::Application.new
      Parse::Stack::Tasks.new.install_tasks
      Rake::Task["parse:env"].clear_prerequisites rescue nil

      ENV.delete(Parse::MongoDB::MUTATION_ENV_KEY)
      err = assert_raises(RuntimeError) do
        Rake::Task["parse:mongo:indexes:apply"].invoke
      end
      assert_match(/PARSE_MONGO_INDEX_MUTATIONS/, err.message)
    ensure
      Rake.application = old_app if defined?(old_app)
      teardown_mongodb_full!
    end
  end
end
