# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Unit tests for `Model.describe` — operator-facing introspection aggregator
# extended onto Parse::Object. Mirrors `Parse::Agent#describe` in shape:
# Hash by default, optional pretty String, never feeds the LLM. Local-only
# by default; opts into server/Mongo fetches via `network: true`.
class ObjectDescribeTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test-app", api_key: "test-key")
    end
  end

  class DescribedAlbum < Parse::Object
    parse_class "DescribedAlbum"
    property :title, :string
    property :year, :integer, default: 1970
    property :status, :string, enum: [:draft, :published]
  end

  class DescribedTrack < Parse::Object
    parse_class "DescribedTrack"
    property :name, :string
    property :duration, :integer
    belongs_to :album, as: :described_album
  end

  # ---- shape ---------------------------------------------------------------

  def test_describe_returns_hash_with_class_name_and_local_sections
    data = DescribedAlbum.describe
    assert_kind_of Hash, data
    assert_equal "DescribedAlbum", data[:class_name]
    assert data.key?(:model), "default output includes :model section"
    assert data.key?(:acl),   "default output includes :acl section"
    refute data.key?(:schema), "default output is local-only — no :schema"
    refute data.key?(:clp),    "default output is local-only — no :clp"
    refute data.key?(:atlas),  "default output is local-only — no :atlas"
  end

  def test_describe_pretty_returns_multiline_string
    out = DescribedAlbum.describe(pretty: true)
    assert_kind_of String, out
    assert_match(/DescribedAlbum describe:/, out)
    assert_match(/fields:/, out)
  end

  def test_describe_accepts_explicit_section_list
    data = DescribedAlbum.describe(:model)
    assert_equal [:class_name, :model], data.keys
  end

  def test_describe_unknown_section_returns_unavailable_envelope
    section = DescribedAlbum.describe(:nope)[:nope]
    refute section[:available]
    assert_equal :unknown_section, section[:reason]
  end

  # ---- :model section ------------------------------------------------------

  def test_model_section_lists_user_declared_fields_only
    m = DescribedAlbum.describe[:model]
    fields = m[:fields]
    assert fields.key?(:title)
    assert fields.key?(:year)
    refute fields.key?(:objectId),  "core fields are filtered out"
    refute fields.key?(:createdAt), "core fields are filtered out"
    refute fields.key?(:ACL),       "core fields are filtered out"
    assert_equal 3, m[:field_count]
  end

  def test_model_section_includes_references_for_belongs_to
    m = DescribedTrack.describe[:model]
    assert_equal "DescribedAlbum", m[:references][:album]
  end

  def test_model_section_includes_defaults_and_enums
    m = DescribedAlbum.describe[:model]
    assert_includes m[:defaults], :year
    assert_equal [:draft, :published], m[:enums][:status]
  end

  # ---- :acl section --------------------------------------------------------

  def test_acl_section_emits_default_acl_json
    a = DescribedAlbum.describe[:acl]
    assert a.key?(:default_acl)
    assert a.key?(:default_acl_private)
  end

  # ---- network gating ------------------------------------------------------

  def test_network_section_short_circuits_when_network_disabled
    section = DescribedAlbum.describe(:schema)[:schema]
    refute section[:available]
    assert_equal :network_disabled, section[:reason]
  end

  def test_atlas_section_reports_mongodb_not_enabled_without_mongo
    # Most CI environments don't configure MongoDB direct access. When
    # not enabled, the section should degrade rather than raise.
    skip "MongoDB direct is configured" if Parse::MongoDB.respond_to?(:enabled?) && Parse::MongoDB.enabled?
    section = DescribedAlbum.describe(:atlas, network: true)[:atlas]
    refute section[:available]
    assert_equal :mongodb_not_enabled, section[:reason]
  end

  def test_indexes_section_reports_mongodb_not_enabled_without_mongo
    skip "MongoDB direct is configured" if Parse::MongoDB.respond_to?(:enabled?) && Parse::MongoDB.enabled?
    section = DescribedAlbum.describe(:indexes, network: true)[:indexes]
    refute section[:available]
    assert_equal :mongodb_not_enabled, section[:reason]
  end

  def test_indexes_section_normalizes_driver_entries_with_mongo_stubbed
    # Stand in for Parse::MongoDB so we can assert the normalization shape
    # without opening a real Mongo connection.
    fake_mongo = Module.new do
      def self.enabled?; true; end
      def self.indexes(_)
        [
          { "name" => "_id_", "key" => { "_id" => 1 } },
          { "name" => "email_1", "key" => { "email" => 1 }, "unique" => true,
            "partialFilterExpression" => { "deleted" => { "$ne" => true } } },
          { "name" => "loc_2dsphere", "key" => { "loc" => "2dsphere" }, "sparse" => true },
        ]
      end
    end
    saved = Parse.const_get(:MongoDB)
    Parse.send(:remove_const, :MongoDB)
    Parse.const_set(:MongoDB, fake_mongo)
    begin
      section = DescribedAlbum.describe(:indexes, network: true)[:indexes]
      assert section[:available]
      assert_equal 3, section[:count]
      id_entry    = section[:indexes].find { |i| i[:name] == "_id_" }
      email_entry = section[:indexes].find { |i| i[:name] == "email_1" }
      geo_entry   = section[:indexes].find { |i| i[:name] == "loc_2dsphere" }
      assert id_entry[:implicit_id], "_id_ must be flagged as implicit"
      assert email_entry[:unique]
      assert_equal({ "deleted" => { "$ne" => true } }, email_entry[:partial_filter])
      assert geo_entry[:sparse]
      assert_equal "2dsphere", geo_entry[:key]["loc"]
    ensure
      Parse.send(:remove_const, :MongoDB)
      Parse.const_set(:MongoDB, saved)
    end
  end

  def test_indexes_section_usage_flag_merges_index_stats
    fake_mongo = Module.new
    fake_mongo.define_singleton_method(:enabled?) { true }
    fake_mongo.define_singleton_method(:indexes) do |_|
      [{ "name" => "ix1", "key" => { "field" => 1 } },
       { "name" => "ix2", "key" => { "other" => 1 } }]
    end
    fake_mongo.define_singleton_method(:index_stats) do |_, master: false|
      # The real `Parse::MongoDB.index_stats` requires `master: true`; mirror
      # that opt-in here so the stub behaves like production. Without the
      # opt-in the production method raises ArgumentError and `describe`
      # never receives stats.
      raise ArgumentError, "index_stats requires master: true" unless master == true
      { "ix1" => { ops: 60_712, since: "T1" },
        "ix2" => { ops: 421,    since: "T1" } }
    end
    saved = Parse.const_get(:MongoDB)
    Parse.send(:remove_const, :MongoDB)
    Parse.const_set(:MongoDB, fake_mongo)
    begin
      section = DescribedAlbum.describe(:indexes, network: true, usage: true, master: true)[:indexes]
      assert section[:available]
      assert_equal true, section[:usage_available]
      ops_by_name = section[:indexes].map { |i| [i[:name], i[:usage] && i[:usage][:ops]] }.to_h
      assert_equal 60_712, ops_by_name["ix1"]
      assert_equal 421,    ops_by_name["ix2"]
    ensure
      Parse.send(:remove_const, :MongoDB)
      Parse.const_set(:MongoDB, saved)
    end
  end

  def test_indexes_section_usage_flag_reports_unavailable_when_role_lacks_cluster_monitor
    fake_mongo = Module.new
    fake_mongo.define_singleton_method(:enabled?) { true }
    fake_mongo.define_singleton_method(:indexes) { |_| [{ "name" => "ix1", "key" => { "field" => 1 } }] }
    # Empty stats Hash == caller passed `master: true` but the Mongo role
    # lacks clusterMonitor / Atlas restricts $indexStats. The production
    # `index_stats` rescues to `{}` in that case; mirror the signature
    # (master: kwarg) so the stub matches production.
    fake_mongo.define_singleton_method(:index_stats) { |_, master: false| {} }
    saved = Parse.const_get(:MongoDB)
    Parse.send(:remove_const, :MongoDB)
    Parse.const_set(:MongoDB, fake_mongo)
    begin
      section = DescribedAlbum.describe(:indexes, network: true, usage: true, master: true)[:indexes]
      assert section[:available]
      assert_equal false, section[:usage_available]
      refute section[:indexes].first.key?(:usage), "no usage merge when stats are empty"
    ensure
      Parse.send(:remove_const, :MongoDB)
      Parse.const_set(:MongoDB, saved)
    end
  end

  def test_indexes_section_coerces_bson_objectid_to_string
    objectid_like = Class.new do
      def to_s; "abc123def4567890abcdef01"; end
    end.new
    fake_mongo = Module.new
    fake_mongo.define_singleton_method(:enabled?) { true }
    fake_mongo.define_singleton_method(:indexes) do |_|
      [{ "name" => "pinned_1", "key" => { "ownerId" => 1 },
         "partialFilterExpression" => { "ownerId" => objectid_like } }]
    end
    saved = Parse.const_get(:MongoDB)
    Parse.send(:remove_const, :MongoDB)
    Parse.const_set(:MongoDB, fake_mongo)
    begin
      section = DescribedAlbum.describe(:indexes, network: true)[:indexes]
      pf = section[:indexes].first[:partial_filter]
      assert_equal "abc123def4567890abcdef01", pf["ownerId"]
    ensure
      Parse.send(:remove_const, :MongoDB)
      Parse.const_set(:MongoDB, saved)
    end
  end

  def test_schema_section_degrades_gracefully_when_server_unreachable
    # Connection failure on the test stub server -> error envelope, not raise.
    section = DescribedAlbum.describe(:schema, network: true)[:schema]
    refute section[:available]
    refute_nil section[:reason]
  end

  # ---- output is structured, never echoes secrets --------------------------

  def test_describe_pretty_does_not_include_raw_inspect_of_core_internals
    out = DescribedAlbum.describe(pretty: true)
    refute_match(/@/, out, "pretty output should not leak instance variable names")
  end
end
