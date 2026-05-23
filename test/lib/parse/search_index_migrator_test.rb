# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/atlas_search"

# Unit tests for Parse::Schema::SearchIndexMigrator. Stubs the
# IndexManager so no Atlas connection is required.
class SearchIndexMigratorTest < Minitest::Test
  IM = Parse::AtlasSearch::IndexManager
  Migrator = Parse::Schema::SearchIndexMigrator

  def setup
    @stubbed_targets = []  # Array<[singleton_class, method_name]>
  end

  def teardown
    @stubbed_targets.reverse_each { |sc, meth| restore_singleton(sc, meth) }
    @stubbed_targets.clear
  end

  # Replace `target`'s singleton method `meth` with `block`. Aliases the
  # original to `__test_orig_<meth>` so teardown can restore it — using
  # `remove_method` alone would leave the singleton without the original
  # implementation and pollute the next test (the atlas_search_test
  # suite calls the real IM.list_indexes and crashes).
  def stub_singleton(target, meth, &block)
    sc = target.singleton_class
    alias_name = "__test_orig_#{meth}".to_sym
    if sc.method_defined?(meth) && !sc.method_defined?(alias_name)
      sc.send(:alias_method, alias_name, meth)
    end
    sc.send(:remove_method, meth) if sc.method_defined?(meth)
    target.define_singleton_method(meth, &block)
    @stubbed_targets << [sc, meth]
  end

  def restore_singleton(sc, meth)
    alias_name = "__test_orig_#{meth}".to_sym
    sc.send(:remove_method, meth) if sc.method_defined?(meth)
    if sc.method_defined?(alias_name)
      sc.send(:alias_method, meth, alias_name)
      sc.send(:remove_method, alias_name)
    end
  end

  # Sugar for IM stubs (the dominant case in this file).
  def stub_im(meth, &block)
    stub_singleton(IM, meth, &block)
  end

  # Make Parse::MongoDB.enabled? report true so the migrator's
  # `fetch_existing_indexes` doesn't short-circuit. Restored in teardown.
  def stub_mongodb_enabled(enabled = true)
    stub_singleton(Parse::MongoDB, :enabled?) { enabled }
  end

  def fresh_model(name = "SIxMigModel#{SecureRandom.hex(4)}")
    klass = Class.new(Parse::Object)
    klass.define_singleton_method(:name) { name }
    klass.parse_class(name)
    klass
  end

  # ---- plan branches ----------------------------------------------------

  def test_plan_classifies_undeclared_as_to_create
    m = fresh_model
    m.mongo_search_index("new_ix", { mappings: { dynamic: true } })
    stub_im(:list_indexes) { |_, force_refresh: false| [] }
    stub_mongodb_enabled
    p = Migrator.new(m).plan
    assert_equal 1, p[:to_create].size
    assert_equal "new_ix", p[:to_create].first[:name]
    assert_empty p[:in_sync]
    assert_empty p[:drifted]
    assert_empty p[:orphans]
    assert p[:atlas_available]
  end

  def test_plan_classifies_matching_definition_as_in_sync
    m = fresh_model
    m.mongo_search_index("ix", { mappings: { dynamic: true } })
    stub_im(:list_indexes) do |_, force_refresh: false|
      [{ "name" => "ix", "latestDefinition" => { "mappings" => { "dynamic" => true } }, "queryable" => true }]
    end
    stub_mongodb_enabled
    p = Migrator.new(m).plan
    assert_empty p[:to_create]
    assert_equal 1, p[:in_sync].size
    assert_empty p[:drifted]
  end

  def test_plan_classifies_definition_drift_as_drifted
    m = fresh_model
    m.mongo_search_index("ix", { mappings: { dynamic: true } })
    stub_im(:list_indexes) do |_, force_refresh: false|
      [{ "name"             => "ix",
         "status"           => "READY",
         "queryable"        => true,
         "latestDefinition" => { "mappings" => { "dynamic" => false, "fields" => { "title" => { "type" => "string" } } } } }]
    end
    stub_mongodb_enabled
    p = Migrator.new(m).plan
    assert_empty p[:to_create]
    assert_empty p[:in_sync]
    assert_equal 1, p[:drifted].size
    entry = p[:drifted].first
    assert_equal "ix", entry[:declared][:name]
    assert_equal "ix", entry[:existing][:name]
    assert_equal "READY", entry[:existing][:status]
  end

  def test_plan_classifies_undeclared_existing_as_orphans
    m = fresh_model
    m.mongo_search_index("declared_ix", { mappings: { dynamic: true } })
    stub_im(:list_indexes) do |_, force_refresh: false|
      [{ "name" => "declared_ix", "latestDefinition" => { "mappings" => { "dynamic" => true } } },
       { "name" => "orphan_one",  "latestDefinition" => { "mappings" => { "dynamic" => false } } },
       { "name" => "orphan_two",  "latestDefinition" => { "mappings" => { "fields" => {} } } }]
    end
    stub_mongodb_enabled
    p = Migrator.new(m).plan
    assert_equal %w[orphan_one orphan_two], p[:orphans]
  end

  def test_plan_treats_symbol_and_string_keys_as_equal
    m = fresh_model
    m.mongo_search_index("ix", { mappings: { dynamic: true, fields: { title: { type: "string" } } } })
    stub_im(:list_indexes) do |_, force_refresh: false|
      [{ "name"             => "ix",
         "latestDefinition" => { "mappings" => { "dynamic" => true, "fields" => { "title" => { "type" => "string" } } } } }]
    end
    stub_mongodb_enabled
    p = Migrator.new(m).plan
    assert_empty p[:drifted], "symbol-keyed declaration must compare equal to string-keyed atlas response"
    assert_equal 1, p[:in_sync].size
  end

  def test_plan_reports_atlas_unavailable_when_mongodb_disabled
    m = fresh_model
    m.mongo_search_index("ix", { mappings: { dynamic: true } })
    stub_mongodb_enabled(false)
    p = Migrator.new(m).plan
    refute p[:atlas_available]
    # With Atlas unavailable, every declaration appears in to_create.
    assert_equal 1, p[:to_create].size
  end

  def test_plan_force_refreshes_index_list
    m = fresh_model
    m.mongo_search_index("ix", { mappings: { dynamic: true } })
    captured = []
    stub_im(:list_indexes) do |_, force_refresh: false|
      captured << force_refresh
      []
    end
    stub_mongodb_enabled
    Migrator.new(m).plan
    assert captured.all? { |f| f == true },
           "plan must bypass IndexManager cache via force_refresh: true"
  end

  # ---- apply! branches --------------------------------------------------

  def test_apply_default_creates_to_create_only
    m = fresh_model
    m.mongo_search_index("new_ix", { mappings: { dynamic: true } })
    create_calls = []
    update_calls = []
    drop_calls   = []
    stub_im(:list_indexes) { |_, force_refresh: false| [] }
    stub_im(:create_index) { |coll, name, defn, **_| create_calls << [coll, name, defn]; :created }
    stub_im(:update_index) { |*args| update_calls << args; :updated }
    stub_im(:drop_index)   { |*args, **_| drop_calls << args; :dropped }
    stub_mongodb_enabled

    r = Migrator.new(m).apply!
    assert_equal 1, create_calls.size
    assert_empty update_calls
    assert_empty drop_calls
    assert_equal 1, r[:created].size
    assert_empty r[:updated]
    assert_empty r[:dropped]
  end

  def test_apply_skips_drifted_by_default_and_reports_in_drifted_skipped
    m = fresh_model
    m.mongo_search_index("ix", { mappings: { dynamic: true } })
    update_calls = []
    stub_im(:list_indexes) do |_, force_refresh: false|
      [{ "name" => "ix", "latestDefinition" => { "mappings" => { "dynamic" => false } } }]
    end
    stub_im(:update_index) { |*args| update_calls << args; :updated }
    stub_mongodb_enabled

    r = Migrator.new(m).apply!
    assert_empty update_calls, "drift must NOT trigger update without explicit update: true"
    assert_equal %w[ix], r[:drifted_skipped]
  end

  def test_apply_with_update_true_rebuilds_drifted_indexes
    m = fresh_model
    m.mongo_search_index("ix", { mappings: { dynamic: true } })
    update_calls = []
    stub_im(:list_indexes) do |_, force_refresh: false|
      [{ "name" => "ix", "latestDefinition" => { "mappings" => { "dynamic" => false } } }]
    end
    stub_im(:update_index) { |coll, name, defn, **_| update_calls << [coll, name, defn]; :updated }
    stub_mongodb_enabled

    r = Migrator.new(m).apply!(update: true)
    assert_equal 1, update_calls.size
    assert_equal %w[ix], r[:updated]
    assert_empty r[:drifted_skipped]
  end

  def test_apply_skips_orphans_by_default_and_reports_in_orphans_skipped
    m = fresh_model
    m.mongo_search_index("declared_ix", { mappings: { dynamic: true } })
    drop_calls = []
    stub_im(:list_indexes) do |_, force_refresh: false|
      [{ "name" => "declared_ix", "latestDefinition" => { "mappings" => { "dynamic" => true } } },
       { "name" => "orphan_ix",   "latestDefinition" => { "mappings" => { "dynamic" => false } } }]
    end
    stub_im(:drop_index) { |*args, **_| drop_calls << args; :dropped }
    stub_mongodb_enabled

    r = Migrator.new(m).apply!
    assert_empty drop_calls, "orphan drop must NOT trigger without explicit drop: true"
    assert_equal %w[orphan_ix], r[:orphans_skipped]
  end

  def test_apply_with_drop_true_drops_orphans_with_correct_confirm_token
    m = fresh_model
    m.parse_class("OrphanModel")
    m.mongo_search_index("declared_ix", { mappings: { dynamic: true } })
    drop_calls = []
    stub_im(:list_indexes) do |_, force_refresh: false|
      [{ "name" => "declared_ix", "latestDefinition" => { "mappings" => { "dynamic" => true } } },
       { "name" => "orphan_ix",   "latestDefinition" => { "mappings" => { "dynamic" => false } } }]
    end
    stub_im(:drop_index) { |coll, name, confirm:, **_| drop_calls << [coll, name, confirm]; :dropped }
    stub_mongodb_enabled

    r = Migrator.new(m).apply!(drop: true)
    assert_equal 1, drop_calls.size
    assert_equal ["OrphanModel", "orphan_ix", "drop_search:OrphanModel:orphan_ix"], drop_calls.first
    assert_equal %w[orphan_ix], r[:dropped]
  end

  def test_apply_drop_runs_before_create
    m = fresh_model
    m.mongo_search_index("new_ix", { mappings: { dynamic: true } })
    operations = []
    stub_im(:list_indexes) do |_, force_refresh: false|
      [{ "name" => "orphan_ix", "latestDefinition" => { "mappings" => { "dynamic" => false } } }]
    end
    stub_im(:drop_index) { |_, name, confirm:, **_| operations << [:drop, name]; :dropped }
    stub_im(:create_index) { |_, name, _, **_| operations << [:create, name]; :created }
    stub_mongodb_enabled

    Migrator.new(m).apply!(drop: true)
    assert_equal [[:drop, "orphan_ix"], [:create, "new_ix"]], operations,
                 "orphan drop must precede create so per-cluster Atlas quota frees a slot first"
  end

  def test_apply_with_wait_polls_after_each_create
    m = fresh_model
    m.mongo_search_index("new_ix", { mappings: { dynamic: true } })
    wait_calls = []
    stub_im(:list_indexes) { |_, force_refresh: false| [] }
    stub_im(:create_index) { |*_| :created }
    stub_im(:wait_for_ready) do |coll, name, **opts|
      wait_calls << [coll, name, opts[:timeout]]
      :ready
    end
    stub_mongodb_enabled

    r = Migrator.new(m).apply!(wait: true, timeout: 42)
    assert_equal 1, wait_calls.size
    assert_equal 42, wait_calls.first.last
    assert_equal({ "new_ix" => :ready }, r[:wait_results])
  end

  def test_apply_with_wait_does_not_poll_when_create_returns_exists
    m = fresh_model
    m.mongo_search_index("new_ix", { mappings: { dynamic: true } })
    wait_calls = []
    stub_im(:list_indexes) { |_, force_refresh: false| [] }
    stub_im(:create_index) { |*_| :exists }
    stub_im(:wait_for_ready) { |*args| wait_calls << args; :ready }
    stub_mongodb_enabled

    r = Migrator.new(m).apply!(wait: true)
    assert_empty wait_calls, "wait must not poll for an already-existing index"
    assert_equal 1, r[:skipped_exists].size
  end
end
