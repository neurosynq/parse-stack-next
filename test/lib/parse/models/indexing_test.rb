# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Unit tests for Parse::Core::Indexing — the model-declarative MongoDB
# index DSL. Validation rules run at declaration time so a typo / parallel
# array / unknown field fails when the class loads, not when an operator
# runs `parse:mongo:indexes:apply` against production.
class IndexingDSLTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test-app", api_key: "test-key")
    end
  end

  class IxAlbum < Parse::Object
    parse_class "IxAlbum"
    property :title, :string
    property :year, :integer
    property :tags, :array
    property :location, :geopoint
    property :vin, :string
    belongs_to :artist, as: :user

    mongo_index :title, :year
    mongo_index :vin, unique: true
    mongo_index :artist
    mongo_geo_index :location
    mongo_index :tags
  end

  # ---- declaration storage -------------------------------------------------

  def test_declarations_accumulate_on_class
    decls = IxAlbum.mongo_index_declarations
    assert_equal 5, decls.size
  end

  def test_compound_keys_preserve_order
    compound = IxAlbum.mongo_index_declarations.first
    assert_equal({ "title" => 1, "year" => 1 }, compound[:keys])
  end

  def test_unique_option_recorded
    vin = IxAlbum.mongo_index_declarations.find { |d| d[:keys].key?("vin") }
    assert_equal true, vin[:options][:unique]
  end

  def test_belongs_to_field_auto_rewrites_to_pointer_column
    artist = IxAlbum.mongo_index_declarations.find { |d| d[:keys].keys.include?("_p_artist") }
    refute_nil artist, "belongs_to :artist must rewrite to _p_artist on the wire"
  end

  def test_geo_index_uses_2dsphere_value
    geo = IxAlbum.mongo_index_declarations.find { |d| d[:keys].values.include?("2dsphere") }
    assert_equal({ "location" => "2dsphere" }, geo[:keys])
  end

  def test_array_field_alone_allowed
    arr = IxAlbum.mongo_index_declarations.find { |d| d[:keys] == { "tags" => 1 } }
    refute_nil arr, "array-typed single-field index must be permitted"
  end

  # ---- unique_index_on (first_or_create! correctness floor) ----------------

  class IxUniqueTuple < Parse::Object
    parse_class "IxUniqueTuple"
    property :email, :string
    belongs_to :tenant, as: :user

    unique_index_on :email, :tenant
  end

  def test_unique_index_on_records_unique
    decl = IxUniqueTuple.mongo_index_declarations.first
    assert_equal true, decl[:options][:unique]
  end

  def test_unique_index_on_compound_preserves_order_and_pointer_rewrite
    decl = IxUniqueTuple.mongo_index_declarations.first
    # email stays as-is; the :tenant pointer rewrites to _p_tenant, in order.
    assert_equal({ "email" => 1, "_p_tenant" => 1 }, decl[:keys])
  end

  def test_unique_index_on_is_non_sparse_by_default
    decl = IxUniqueTuple.mongo_index_declarations.first
    # sparse:false is dropped from options (see register_index reject), so the
    # index key stays identical to the dedup tuple first_or_create! re-queries.
    refute decl[:options].key?(:sparse),
           "unique_index_on must default to non-sparse so the key matches the recovery query"
  end

  def test_unique_index_on_sparse_true_is_honored
    klass = Class.new(Parse::Object) do
      def self.name; "IxUniqSparse"; end
      property :slug, :string
      unique_index_on :slug, sparse: true
    end
    decl = klass.mongo_index_declarations.first
    assert_equal true, decl[:options][:unique]
    assert_equal true, decl[:options][:sparse]
  end

  def test_unique_index_on_partial_filter_is_honored
    klass = Class.new(Parse::Object) do
      def self.name; "IxUniqPartial"; end
      property :email, :string
      belongs_to :tenant, as: :user
      unique_index_on :email, :tenant,
                      partial: { "_p_tenant" => { "$exists" => true } }
    end
    decl = klass.mongo_index_declarations.first
    assert_equal({ "_p_tenant" => { "$exists" => true } }, decl[:options][:partial_filter])
  end

  def test_unique_index_on_inherits_sensitive_field_guard
    err = assert_raises(ArgumentError) do
      Class.new(Parse::Object) do
        def self.name; "IxUniqSensitive"; end
        unique_index_on :_hashed_password
      end
    end
    assert_match(/sensitive Parse-internal columns/, err.message)
  end

  def test_unique_index_on_inherits_unknown_field_guard
    err = assert_raises(ArgumentError) do
      Class.new(Parse::Object) do
        def self.name; "IxUniqUnknown"; end
        unique_index_on :nope
      end
    end
    assert_match(/unknown field/, err.message)
  end

  def test_unique_index_on_dedupes_against_equivalent_mongo_index
    klass = Class.new(Parse::Object) do
      def self.name; "IxUniqDedupe"; end
      property :code, :string
      mongo_index :code, unique: true
      unique_index_on :code           # same key + same options → idempotent
    end
    matching = klass.mongo_index_declarations.select { |d| d[:keys] == { "code" => 1 } }
    assert_equal 1, matching.size,
                 "unique_index_on and an equivalent mongo_index must collapse to one declaration"
  end

  # ---- validation: parallel arrays ----------------------------------------

  def test_compound_with_two_array_properties_rejected
    err = assert_raises(ArgumentError) do
      Class.new(Parse::Object) do
        def self.name; "IxArr1"; end
        property :a, :array
        property :b, :array
        mongo_index :a, :b
      end
    end
    assert_match(/parallel arrays/, err.message)
  end

  def test_compound_with_array_and_rperm_rejected
    err = assert_raises(ArgumentError) do
      Class.new(Parse::Object) do
        def self.name; "IxArr2"; end
        property :tags, :array
        mongo_index :tags, :_rperm
      end
    end
    assert_match(/parallel arrays/, err.message)
  end

  # ---- validation: unknown / relation fields ------------------------------

  def test_unknown_field_rejected
    err = assert_raises(ArgumentError) do
      Class.new(Parse::Object) do
        def self.name; "IxUnk"; end
        mongo_index :nonexistent_property
      end
    end
    assert_match(/unknown field/, err.message)
  end

  def test_relation_field_rejected
    klass = Class.new(Parse::Object) do
      def self.name; "IxRel"; end
      has_many :memberships, through: :relation, as: :ix_album
    end
    err = assert_raises(ArgumentError) { klass.mongo_index :memberships }
    assert_match(/Parse Relation/, err.message)
  end

  def test_empty_field_list_rejected
    klass = Class.new(Parse::Object) { def self.name; "IxEmpty"; end }
    err = assert_raises(ArgumentError) { klass.mongo_index }
    assert_match(/at least one field/, err.message)
  end

  # ---- validation: expire_after constraints --------------------------------

  def test_expire_after_with_compound_rejected
    klass = Class.new(Parse::Object) do
      def self.name; "IxExp"; end
      property :a, :date
      property :b, :integer
    end
    err = assert_raises(ArgumentError) { klass.mongo_index :a, :b, expire_after: 3600 }
    assert_match(/expire_after is only valid on single-field/, err.message)
  end

  # ---- internal fields allowed for operator-targeted indexes --------------

  def test_internal_underscore_field_allowed
    klass = Class.new(Parse::Object) { def self.name; "IxInt"; end }
    decl = klass.mongo_index :_rperm
    assert_equal({ "_rperm" => 1 }, decl[:keys])
  end
end

# ---- sensitive-field guard (TRACK-MISC-2) -------------------------------

class SensitiveFieldGuardTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test-app", api_key: "test-key")
    end
  end

  # Every entry in SENSITIVE_FIELDS — declared on its own (which would
  # otherwise be allowed by `internal_or_declared?`'s `_`-prefix bypass)
  # — must be refused. A queryable index on bcrypt hashes or session
  # tokens turns $indexStats access into a credential-enumeration oracle.
  Parse::Core::Indexing::SENSITIVE_FIELDS.each do |field|
    define_method(:"test_refuses_mongo_index_on_#{field}") do
      klass = Class.new(Parse::Object) { def self.name; "SensGuard"; end }
      err = assert_raises(ArgumentError) { klass.mongo_index field.to_sym }
      assert_match(/sensitive Parse-internal columns/, err.message)
      assert_match(/#{Regexp.escape(field)}/, err.message)
    end
  end

  # Compound declarations that mix a benign field with a sensitive one
  # are still refused — the sensitive column is in `wire_keys` regardless
  # of position.
  def test_refuses_compound_when_one_leg_is_sensitive
    klass = Class.new(Parse::Object) do
      def self.name; "SensGuardCompound"; end
      property :email, :string
    end
    err = assert_raises(ArgumentError) do
      klass.mongo_index :email, :_session_token
    end
    assert_match(/sensitive Parse-internal columns/, err.message)
    assert_match(/_session_token/, err.message)
  end

  # Unique constraint must not be a bypass — the denylist runs before
  # any option-driven branch.
  def test_refuses_mongo_index_unique_on_sensitive_field
    klass = Class.new(Parse::Object) { def self.name; "SensGuardUnique"; end }
    assert_raises(ArgumentError) do
      klass.mongo_index :_hashed_password, unique: true
    end
  end

  # Non-sensitive internal fields (e.g. _rperm) are still allowed —
  # the denylist must not over-block legitimate operator-targeted
  # indexes like ACL columns.
  def test_allows_mongo_index_on_non_sensitive_internal_field
    klass = Class.new(Parse::Object) { def self.name; "SensGuardOK"; end }
    decl = klass.mongo_index :_rperm
    assert_equal({ "_rperm" => 1 }, decl[:keys])
  end
end

# ---- IndexMigrator -------------------------------------------------------

class IndexMigratorTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test-app", api_key: "test-key")
    end
  end

  class MgCar < Parse::Object
    parse_class "MgCar"
    property :make, :string
    property :model, :string
    property :year, :integer
    property :vin, :string
    belongs_to :owner, as: :user
    mongo_index :make, :model, :year
    mongo_index :vin, unique: true
    mongo_index :owner
  end

  def with_stubbed_indexes(existing)
    saved_indexes = Parse::MongoDB.method(:indexes)
    saved_enabled = Parse::MongoDB.method(:enabled?)
    Parse::MongoDB.singleton_class.define_method(:enabled?) { true }
    Parse::MongoDB.singleton_class.define_method(:indexes) { |_| existing }
    yield
  ensure
    Parse::MongoDB.singleton_class.define_method(:enabled?, &saved_enabled)
    Parse::MongoDB.singleton_class.define_method(:indexes, &saved_indexes)
  end

  def test_plan_classifies_to_create_in_sync_orphan_parse_managed
    with_stubbed_indexes([
      { "name" => "_id_", "key" => { "_id" => 1 } },
      { "name" => "vin_1", "key" => { "vin" => 1 }, "unique" => true },
      { "name" => "stray_idx", "key" => { "manufactured" => 1 } },
    ]) do
      plans = Parse::Schema::IndexMigrator.new(MgCar).plan
      p = plans["MgCar"]
      refute_nil p
      assert_equal "MgCar", p[:collection]
      assert_includes p[:parse_managed], "_id_"
      assert_equal 2, p[:to_create].size
      assert_equal 1, p[:in_sync].size
      assert_includes p[:orphans], "stray_idx"
    end
  end

  def test_plan_reports_capacity_math
    with_stubbed_indexes([{ "name" => "_id_", "key" => { "_id" => 1 } }]) do
      p = Parse::Schema::IndexMigrator.new(MgCar).plan["MgCar"]
      assert_equal 1, p[:capacity_used]
      assert_equal 4, p[:capacity_after]
      assert_equal 60, p[:capacity_remaining]
      assert p[:capacity_ok]
    end
  end

  def test_plan_capacity_blocked_when_over_64
    # 62 existing + 3 to-create = 65 -> blocked
    existing = (1..62).map { |i| { "name" => "ix#{i}", "key" => { "f#{i}" => 1 } } }
    with_stubbed_indexes(existing) do
      p = Parse::Schema::IndexMigrator.new(MgCar).plan["MgCar"]
      refute p[:capacity_ok], "capacity must report blocked when projected total > 64"
      assert p[:capacity_remaining] < 0
    end
  end

  def test_plan_capacity_with_drop_accounts_for_orphan_removal
    # 62 existing: _id_ (managed, excluded from count math) + 61
    # orphans (60 obsoletes + 1 stray that doesn't match any MgCar
    # declaration). MgCar has 3 declared. Additive: 62 + 3 = 65
    # (blocked). With drop: 65 - 61 = 4 (fits).
    existing = (1..60).map { |i| { "name" => "obsolete#{i}", "key" => { "g#{i}" => 1 } } }
    existing << { "name" => "_id_", "key" => { "_id" => 1 } }
    existing << { "name" => "stray_idx", "key" => { "manufactured" => 1 } }
    with_stubbed_indexes(existing) do
      p = Parse::Schema::IndexMigrator.new(MgCar).plan["MgCar"]
      refute p[:capacity_ok], "additive-mode must report blocked"
      assert p[:capacity_ok_with_drop], "drop-mode must report fits after orphan removal"
      assert_equal 61, p[:orphans].size
      assert_equal p[:capacity_after] - 61, p[:capacity_after_with_drop]
    end
  end

  def test_apply_for_uses_drop_capacity_when_drop_true
    # Same scenario as the plan test: at the cap until orphans are
    # dropped. apply_for!(drop: true) must NOT report capacity_blocked
    # in this case because drops free the necessary slots.
    existing = (1..60).map { |i| { "name" => "obsolete#{i}", "key" => { "g#{i}" => 1 } } }
    existing << { "name" => "_id_", "key" => { "_id" => 1 } }
    existing << { "name" => "stray_idx", "key" => { "manufactured" => 1 } }

    fake_mongo = Module.new
    fake_mongo.define_singleton_method(:enabled?) { true }
    fake_mongo.define_singleton_method(:indexes) { |_| existing }
    call_log = []
    fake_mongo.define_singleton_method(:create_index) do |coll, _keys, **_kwargs|
      call_log << [:create, coll]
      :created
    end
    fake_mongo.define_singleton_method(:drop_index) do |coll, name, **_kwargs|
      call_log << [:drop, coll, name]
      :dropped
    end

    saved = Parse.const_get(:MongoDB)
    Parse.send(:remove_const, :MongoDB)
    Parse.const_set(:MongoDB, fake_mongo)
    begin
      migrator = Parse::Schema::IndexMigrator.new(MgCar)
      result = migrator.apply_for!("MgCar", drop: true)
      refute result[:capacity_blocked],
        "drop: true must not report capacity_blocked when orphan removal makes room"
      assert_equal 61, result[:dropped].size
      # Drops must precede creates so the actual MongoDB state has the
      # freed slots before any create_index call runs. The first
      # operation in the call log must be a drop, and every drop must
      # come before every create.
      first_create_idx = call_log.index { |entry| entry[0] == :create }
      last_drop_idx = call_log.rindex { |entry| entry[0] == :drop }
      refute_nil first_create_idx, "expected at least one create_index call"
      refute_nil last_drop_idx, "expected at least one drop_index call"
      assert last_drop_idx < first_create_idx,
        "all drops must precede all creates so freed slots are available"
    ensure
      Parse.send(:remove_const, :MongoDB)
      Parse.const_set(:MongoDB, saved)
    end
  end

  def test_plan_treats_parse_managed_names_as_off_limits
    with_stubbed_indexes([
      { "name" => "_id_", "key" => { "_id" => 1 } },
      { "name" => "_session_token_1", "key" => { "_session_token" => 1 } },
      { "name" => "_email_verify_token_1", "key" => { "_email_verify_token" => 1 } },
    ]) do
      p = Parse::Schema::IndexMigrator.new(MgCar).plan["MgCar"]
      assert_includes p[:parse_managed], "_id_"
      assert_includes p[:parse_managed], "_session_token_1"
      assert_includes p[:parse_managed], "_email_verify_token_1"
      assert_empty p[:orphans], "Parse-managed indexes must never appear as orphans"
    end
  end
end

# ---- mongo_relation_index ------------------------------------------------

class RelationIndexDSLTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test-app", api_key: "test-key")
    end
  end

  class RxRole < Parse::Object
    parse_class "_Role"
    has_many :users, through: :relation
    mongo_relation_index :users, bidirectional: true
  end

  class RxAlbum < Parse::Object
    parse_class "RxAlbum"
    has_many :songs, through: :relation, as: :rx_song
    mongo_relation_index :songs
  end

  def test_relation_index_registers_against_join_collection
    decls = RxAlbum.mongo_index_declarations
    refute_empty decls
    decls.each do |d|
      assert_equal "_Join:songs:RxAlbum", d[:collection]
    end
  end

  def test_relation_index_default_is_owning_id_only
    decls = RxAlbum.mongo_index_declarations
    assert_equal 1, decls.size
    assert_equal({ "owningId" => 1 }, decls.first[:keys])
  end

  def test_relation_index_bidirectional_registers_two_separate_declarations
    decls = RxRole.mongo_index_declarations
    assert_equal 2, decls.size, "bidirectional must register exactly two declarations"
    keys = decls.map { |d| d[:keys] }
    assert_includes keys, { "owningId"  => 1 }
    assert_includes keys, { "relatedId" => 1 }
    decls.each do |d|
      assert_equal "_Join:users:_Role", d[:collection]
    end
  end

  def test_relation_index_routes_to_join_collection_in_plan
    saved_enabled = Parse::MongoDB.method(:enabled?)
    saved_indexes = Parse::MongoDB.method(:indexes)
    Parse::MongoDB.singleton_class.define_method(:enabled?) { true }
    Parse::MongoDB.singleton_class.define_method(:indexes) do |coll|
      coll == "_Join:users:_Role" ? [{ "name" => "_id_", "key" => { "_id" => 1 } }] : []
    end
    begin
      plans = Parse::Schema::IndexMigrator.new(RxRole).plan
      assert_equal ["_Join:users:_Role"], plans.keys
      assert_equal 2, plans["_Join:users:_Role"][:to_create].size
    ensure
      Parse::MongoDB.singleton_class.define_method(:enabled?, &saved_enabled)
      Parse::MongoDB.singleton_class.define_method(:indexes, &saved_indexes)
    end
  end

  def test_relation_index_rejects_non_relation_field
    klass = Class.new(Parse::Object) do
      def self.name; "RxBad"; end
      property :title, :string
    end
    err = assert_raises(ArgumentError) { klass.mongo_relation_index :title }
    assert_match(/has_many.*through: :relation/, err.message)
  end

  def test_relation_index_rejects_unique
    klass = Class.new(Parse::Object) do
      def self.name; "RxUniq"; end
      has_many :tags, through: :relation
    end
    err = assert_raises(ArgumentError) { klass.mongo_relation_index :tags, unique: true }
    assert_match(/does not support unique/, err.message)
    assert_match(/dedup: true/, err.message)
  end

  class RxDedup < Parse::Object
    parse_class "RxDedup"
    has_many :tags, through: :relation
    mongo_relation_index :tags, dedup: true
  end

  class RxDedupBidi < Parse::Object
    parse_class "RxDedupBidi"
    has_many :members, through: :relation, as: :user
    mongo_relation_index :members, bidirectional: true, dedup: true
  end

  def test_relation_index_dedup_registers_compound_unique
    decls = RxDedup.mongo_index_declarations
    compound = decls.find { |d| d[:keys] == { "owningId" => 1, "relatedId" => 1 } }
    refute_nil compound, "dedup: must register a compound owningId/relatedId index"
    assert_equal "_Join:tags:RxDedup", compound[:collection]
    assert_equal true, compound[:options][:unique]
  end

  def test_relation_index_dedup_pairs_with_bidirectional
    decls = RxDedupBidi.mongo_index_declarations
    assert_equal 3, decls.size, "bidirectional + dedup: must register three declarations"
    keys = decls.map { |d| d[:keys] }
    assert_includes keys, { "owningId"  => 1 }
    assert_includes keys, { "relatedId" => 1 }
    assert_includes keys, { "owningId" => 1, "relatedId" => 1 }
    compound = decls.find { |d| d[:keys] == { "owningId" => 1, "relatedId" => 1 } }
    assert_equal true, compound[:options][:unique]
  end
end

# ---- multi-collection apply error isolation ------------------------------

class MultiCollectionApplyIsolationTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test-app", api_key: "test-key")
    end
  end

  class MgcMixed < Parse::Object
    parse_class "MgcMixed"
    property :title, :string
    has_many :tags, through: :relation, as: :user
    mongo_index :title
    mongo_relation_index :tags
  end

  # When apply! iterates collections, a failure on one collection's
  # create_index must NOT prevent the next collection from being
  # processed. Each per-collection entry in the result Hash carries
  # its own outcome independently.
  def test_apply_continues_to_next_collection_after_one_collection_raises
    fake_mongo = Module.new
    fake_mongo.define_singleton_method(:enabled?) { true }
    fake_mongo.define_singleton_method(:indexes) { |_| [] }
    # First create_index call fails (simulating a connection blip on
    # the parent collection), second succeeds (the join collection).
    call_count = 0
    fake_mongo.define_singleton_method(:create_index) do |coll, _keys, **_kwargs|
      call_count += 1
      raise "transient driver failure" if coll == "MgcMixed"
      :created
    end
    fake_mongo.define_singleton_method(:drop_index) { |*| :absent }

    saved = Parse.const_get(:MongoDB)
    Parse.send(:remove_const, :MongoDB)
    Parse.const_set(:MongoDB, fake_mongo)
    begin
      migrator = Parse::Schema::IndexMigrator.new(MgcMixed)
      err = assert_raises(RuntimeError) { migrator.apply! }
      # The error surfaces — but the migrator MUST have attempted the
      # parent collection BEFORE bailing. After the fix, we'll expect
      # both collections to be attempted.
      assert_match(/transient/, err.message)
    ensure
      Parse.send(:remove_const, :MongoDB)
      Parse.const_set(:MongoDB, saved)
    end
  end

  # The per-collection apply_for! method must isolate errors so the
  # caller can iterate `target_collections` manually and skip the
  # failing one without affecting siblings. This is the foundation
  # for any future best-effort iteration mode.
  def test_apply_for_isolates_one_collections_failure_from_another
    fake_mongo = Module.new
    fake_mongo.define_singleton_method(:enabled?) { true }
    fake_mongo.define_singleton_method(:indexes) { |_| [] }
    fake_mongo.define_singleton_method(:create_index) do |coll, _keys, **_kwargs|
      raise "boom" if coll == "MgcMixed"
      :created
    end

    saved = Parse.const_get(:MongoDB)
    Parse.send(:remove_const, :MongoDB)
    Parse.const_set(:MongoDB, fake_mongo)
    begin
      migrator = Parse::Schema::IndexMigrator.new(MgcMixed)
      # Per-collection call against the join collection works:
      result = migrator.apply_for!("_Join:tags:MgcMixed")
      assert_equal 1, result[:created].size, "join collection apply must succeed independently"
      # And the failing parent raises:
      assert_raises(RuntimeError) { migrator.apply_for!("MgcMixed") }
    ensure
      Parse.send(:remove_const, :MongoDB)
      Parse.const_set(:MongoDB, saved)
    end
  end
end

# ---- _id guard ------------------------------------------------------------

class IdFieldGuardTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test-app", api_key: "test-key")
    end
  end

  def test_explicit_id_field_index_rejected
    klass = Class.new(Parse::Object) { def self.name; "IdGuard1"; end }
    err = assert_raises(ArgumentError) { klass.mongo_index :_id }
    assert_match(/_id/, err.message)
    assert_match(/auto-managed/, err.message)
  end
end

# ---- Parse::MongoDB writer gates ----------------------------------------

class MongoDBWriterGatesTest < Minitest::Test
  def setup
    # Save state, reset between tests so we control the gate values.
    @saved_writer_enabled = Parse::MongoDB.instance_variable_get(:@writer_enabled)
    @saved_writer_uri     = Parse::MongoDB.instance_variable_get(:@writer_uri)
    @saved_mut            = Parse::MongoDB.index_mutations_enabled
    @saved_env            = ENV[Parse::MongoDB::MUTATION_ENV_KEY]
    Parse::MongoDB.instance_variable_set(:@writer_uri, nil)
    Parse::MongoDB.instance_variable_set(:@writer_enabled, false)
    Parse::MongoDB.index_mutations_enabled = false
    ENV.delete(Parse::MongoDB::MUTATION_ENV_KEY)
  end

  def teardown
    Parse::MongoDB.instance_variable_set(:@writer_uri, @saved_writer_uri)
    Parse::MongoDB.instance_variable_set(:@writer_enabled, @saved_writer_enabled)
    Parse::MongoDB.index_mutations_enabled = @saved_mut
    if @saved_env.nil?
      ENV.delete(Parse::MongoDB::MUTATION_ENV_KEY)
    else
      ENV[Parse::MongoDB::MUTATION_ENV_KEY] = @saved_env
    end
  end

  def test_create_index_raises_without_writer_configured
    err = assert_raises(Parse::MongoDB::WriterNotConfigured) do
      Parse::MongoDB.create_index("Foo", { name: 1 })
    end
    assert_match(/configure_writer/, err.message)
  end

  def test_create_index_raises_without_index_mutations_enabled
    Parse::MongoDB.instance_variable_set(:@writer_uri, "mongodb://stub")
    Parse::MongoDB.instance_variable_set(:@writer_enabled, true)
    err = assert_raises(Parse::MongoDB::MutationsDisabled) do
      Parse::MongoDB.create_index("Foo", { name: 1 })
    end
    assert_match(/index_mutations_enabled/, err.message)
  end

  def test_create_index_raises_without_env_flag
    Parse::MongoDB.instance_variable_set(:@writer_uri, "mongodb://stub")
    Parse::MongoDB.instance_variable_set(:@writer_enabled, true)
    Parse::MongoDB.index_mutations_enabled = true
    err = assert_raises(Parse::MongoDB::MutationsDisabled) do
      Parse::MongoDB.create_index("Foo", { name: 1 })
    end
    assert_match(/PARSE_MONGO_INDEX_MUTATIONS/, err.message)
  end

  def test_create_index_forbids_parse_internal_classes
    Parse::MongoDB.instance_variable_set(:@writer_uri, "mongodb://stub")
    Parse::MongoDB.instance_variable_set(:@writer_enabled, true)
    Parse::MongoDB.index_mutations_enabled = true
    ENV[Parse::MongoDB::MUTATION_ENV_KEY] = "1"
    err = assert_raises(Parse::MongoDB::ForbiddenCollection) do
      Parse::MongoDB.create_index("_User", { username: 1 })
    end
    assert_match(/_User/, err.message)
    assert_match(/allow_system_classes/, err.message)
  end

  def test_create_index_rejects_invalid_collection_name
    Parse::MongoDB.instance_variable_set(:@writer_uri, "mongodb://stub")
    Parse::MongoDB.instance_variable_set(:@writer_enabled, true)
    Parse::MongoDB.index_mutations_enabled = true
    ENV[Parse::MongoDB::MUTATION_ENV_KEY] = "1"
    assert_raises(Parse::MongoDB::ForbiddenCollection) do
      Parse::MongoDB.create_index("bad-name!", { x: 1 })
    end
  end

  def test_drop_index_requires_correct_confirmation_string
    Parse::MongoDB.instance_variable_set(:@writer_uri, "mongodb://stub")
    Parse::MongoDB.instance_variable_set(:@writer_enabled, true)
    Parse::MongoDB.index_mutations_enabled = true
    ENV[Parse::MongoDB::MUTATION_ENV_KEY] = "1"
    err = assert_raises(ArgumentError) do
      Parse::MongoDB.drop_index("Song", "title_1", confirm: "yes")
    end
    assert_match(/confirm: "drop:Song:title_1"/, err.message)
  end

  def test_configure_writer_rejects_matching_reader_uri
    Parse::MongoDB.instance_variable_set(:@uri, "mongodb://same")
    err = assert_raises(ArgumentError) do
      Parse::MongoDB.configure_writer(uri: "mongodb://same", verify_role: false)
    end
    assert_match(/differ from the reader/, err.message)
  ensure
    Parse::MongoDB.instance_variable_set(:@uri, nil)
  end

  def test_configure_writer_requires_uri
    assert_raises(ArgumentError) { Parse::MongoDB.configure_writer(uri: nil) }
    assert_raises(ArgumentError) { Parse::MongoDB.configure_writer(uri: "") }
  end

  def test_writer_client_is_not_publicly_exposed
    # Security invariant — writer_client must not be reachable via public
    # method call. Use private send to verify it exists, then assert the
    # public interface refuses.
    refute Parse::MongoDB.public_methods.include?(:writer_client),
           "writer_client must not be a public method; it would bypass the gate model"
  end
end
