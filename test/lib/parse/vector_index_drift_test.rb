# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/embeddings"

# Unit tests for first-query vectorSearch index drift verification
# (Parse::Core::VectorSearchable#verify_vector_index!): dimension /
# similarity mismatch detection, tenant-scope filter-path coverage,
# the warn/raise/ignore policy, and the once-per-(field,index) cache.
class VectorIndexDriftTest < Minitest::Test
  def self.register
    Parse::Embeddings.register(:fx_drift, Parse::Embeddings::Fixture.new(dimensions: 4))
  end
  register

  class DriftItem < Parse::Object
    parse_class "DriftItem"
    property :title, :string
    property :embedding, :vector, dimensions: 4, provider: :fx_drift, similarity: :cosine
  end

  def teardown
    Parse::VectorSearch.index_drift_policy = :warn
    DriftItem.instance_variable_set(:@_verified_vector_indexes, nil)
  end

  def index_fixture(dims: 4, similarity: "cosine", filters: [], name: "drift_idx")
    fields = [{ "type" => "vector", "path" => "embedding",
                "numDimensions" => dims, "similarity" => similarity }]
    filters.each { |p| fields << { "type" => "filter", "path" => p } }
    { "name" => name, "type" => "vectorSearch",
      "latestDefinition" => { "fields" => fields } }
  end

  def findings_for(idx)
    DriftItem.send(:vector_index_drift_findings, :embedding, idx)
  end

  def test_in_sync_index_yields_no_findings
    assert_empty findings_for(index_fixture)
  end

  def test_dimension_mismatch_detected
    findings = findings_for(index_fixture(dims: 1536))
    assert_equal 1, findings.length
    assert_includes findings.first, "numDimensions=1536"
    assert_includes findings.first, "dimensions: 4"
  end

  def test_similarity_mismatch_detected
    findings = findings_for(index_fixture(similarity: "dotProduct"))
    assert_equal 1, findings.length
    assert_includes findings.first, "dotProduct"
  end

  def test_missing_index_similarity_is_not_drift
    idx = index_fixture
    idx["latestDefinition"]["fields"].first.delete("similarity")
    assert_empty findings_for(idx)
  end

  def test_warn_policy_does_not_raise
    Parse::VectorSearch.index_drift_policy = :warn
    out = capture_warn do
      DriftItem.send(:verify_vector_index!, :embedding, index_fixture(dims: 99))
    end
    assert_includes out, "[Parse::VectorSearch:DRIFT]"
  end

  def test_raise_policy_raises_with_findings
    Parse::VectorSearch.index_drift_policy = :raise
    err = assert_raises(Parse::Core::VectorSearchable::IndexDriftError) do
      DriftItem.send(:verify_vector_index!, :embedding, index_fixture(dims: 99))
    end
    assert_equal 1, err.findings.length
  end

  def test_ignore_policy_skips_verification
    Parse::VectorSearch.index_drift_policy = :ignore
    out = capture_warn do
      DriftItem.send(:verify_vector_index!, :embedding, index_fixture(dims: 99))
    end
    assert_equal "", out
  end

  def test_raise_policy_raises_on_every_query
    Parse::VectorSearch.index_drift_policy = :raise
    bad = index_fixture(dims: 99)
    assert_raises(Parse::Core::VectorSearchable::IndexDriftError) do
      DriftItem.send(:verify_vector_index!, :embedding, bad)
    end
    # Strict mode: the cached findings keep raising — a drifted index
    # must never serve results after the first failure.
    assert_raises(Parse::Core::VectorSearchable::IndexDriftError) do
      DriftItem.send(:verify_vector_index!, :embedding, bad)
    end
  end

  def test_findings_computed_once_per_field_index_pair
    Parse::VectorSearch.index_drift_policy = :warn
    good = index_fixture
    capture_warn { DriftItem.send(:verify_vector_index!, :embedding, good) }
    cache = DriftItem.instance_variable_get(:@_verified_vector_indexes)
    assert_equal [], cache["embedding|drift_idx"]
    # Second call returns via the cache without recomputing findings.
    DriftItem.stub(:vector_index_drift_findings, ->(*) { flunk "recomputed" }) do
      DriftItem.send(:verify_vector_index!, :embedding, good)
    end
  end

  def test_warn_policy_warns_only_on_first_check
    Parse::VectorSearch.index_drift_policy = :warn
    bad = index_fixture(dims: 99)
    first = capture_warn { DriftItem.send(:verify_vector_index!, :embedding, bad) }
    assert_includes first, "[Parse::VectorSearch:DRIFT]"
    second = capture_warn { DriftItem.send(:verify_vector_index!, :embedding, bad) }
    assert_equal "", second
  end

  def test_policy_escalation_after_first_check_takes_effect
    # A deployment that boots under :warn and flips to :raise (e.g. in a
    # console) should start failing without a process restart.
    Parse::VectorSearch.index_drift_policy = :warn
    bad = index_fixture(dims: 99)
    capture_warn { DriftItem.send(:verify_vector_index!, :embedding, bad) }
    Parse::VectorSearch.index_drift_policy = :raise
    assert_raises(Parse::Core::VectorSearchable::IndexDriftError) do
      DriftItem.send(:verify_vector_index!, :embedding, bad)
    end
  end

  def test_policy_writer_validates
    assert_raises(ArgumentError) { Parse::VectorSearch.index_drift_policy = :loud }
    Parse::VectorSearch.index_drift_policy = :raise
    assert_equal :raise, Parse::VectorSearch.index_drift_policy
  end

  def test_policy_writer_rejects_nil_with_argument_error
    err = assert_raises(ArgumentError) { Parse::VectorSearch.index_drift_policy = nil }
    assert_includes err.message, "must be one of"
    err = assert_raises(ArgumentError) { Parse::VectorSearch.index_drift_policy = 42 }
    assert_includes err.message, "must be one of"
  end

  # ---- verify_explicit_vector_index (explicit index: kwarg) --------------
  # The auto-discovery path verifies what it resolves; an explicit index:
  # kwarg is drift-verified best-effort when the catalog's covering index
  # carries the same name, and skipped (never failed) otherwise.

  def test_explicit_index_with_matching_name_is_drift_verified
    require "parse/atlas_search"
    Parse::VectorSearch.index_drift_policy = :raise
    drifted = index_fixture(dims: 99)
    Parse::AtlasSearch::IndexCatalog.stub(:find_vector_index, drifted) do
      assert_raises(Parse::Core::VectorSearchable::IndexDriftError) do
        DriftItem.send(:verify_explicit_vector_index, :embedding, "drift_idx")
      end
    end
  end

  def test_explicit_index_with_different_name_skips_verification
    require "parse/atlas_search"
    Parse::VectorSearch.index_drift_policy = :raise
    # The catalog's covering index ("drift_idx") is drifted, but the
    # explicit kwarg targets a different index — an override, not a
    # discovery request, so verification is skipped without warning.
    drifted = index_fixture(dims: 99)
    Parse::AtlasSearch::IndexCatalog.stub(:find_vector_index, drifted) do
      out = capture_warn do
        DriftItem.send(:verify_explicit_vector_index, :embedding, "other_idx")
      end
      assert_equal "", out
    end
  end

  def test_explicit_index_skips_when_catalog_lookup_fails
    require "parse/atlas_search"
    Parse::VectorSearch.index_drift_policy = :raise
    boom = ->(*_a, **_kw) { raise StandardError, "catalog unavailable" }
    Parse::AtlasSearch::IndexCatalog.stub(:find_vector_index, boom) do
      out = capture_warn do
        DriftItem.send(:verify_explicit_vector_index, :embedding, "drift_idx")
      end
      assert_equal "", out
    end
  end

  def test_explicit_index_skips_when_catalog_has_no_index
    require "parse/atlas_search"
    Parse::VectorSearch.index_drift_policy = :raise
    Parse::AtlasSearch::IndexCatalog.stub(:find_vector_index, nil) do
      out = capture_warn do
        DriftItem.send(:verify_explicit_vector_index, :embedding, "drift_idx")
      end
      assert_equal "", out
    end
  end

  def test_explicit_index_ignore_policy_skips_catalog_lookup
    require "parse/atlas_search"
    Parse::VectorSearch.index_drift_policy = :ignore
    untouched = ->(*) { flunk "catalog consulted under :ignore" }
    Parse::AtlasSearch::IndexCatalog.stub(:find_vector_index, untouched) do
      out = capture_warn do
        DriftItem.send(:verify_explicit_vector_index, :embedding, "drift_idx")
      end
      assert_equal "", out
    end
  end

  def test_resolve_with_explicit_index_runs_drift_verification
    require "parse/atlas_search"
    Parse::VectorSearch.index_drift_policy = :raise
    drifted = index_fixture(dims: 99)
    Parse::AtlasSearch::IndexCatalog.stub(:find_vector_index, drifted) do
      assert_raises(Parse::Core::VectorSearchable::IndexDriftError) do
        DriftItem.send(:resolve_vector_index!, :embedding, "drift_idx")
      end
    end
  end

  def test_resolve_with_explicit_index_returns_it_when_in_sync
    require "parse/atlas_search"
    Parse::VectorSearch.index_drift_policy = :raise
    Parse::AtlasSearch::IndexCatalog.stub(:find_vector_index, index_fixture) do
      assert_equal "drift_idx",
                   DriftItem.send(:resolve_vector_index!, :embedding, "drift_idx")
    end
  end

  def test_tenant_scope_filter_coverage
    Parse::Agent::MetadataRegistry.register_tenant_scope("DriftItem", :tenant, from: ->(_a) { "t1" })
    begin
      findings = findings_for(index_fixture) # no filter path declared
      assert_equal 1, findings.length
      assert_includes findings.first, "tenant"
      assert_includes findings.first, "filter"

      assert_empty findings_for(index_fixture(filters: ["tenant"]))
    ensure
      # Remove the registration so other tests see a clean registry.
      Parse::Agent::MetadataRegistry.instance_variable_get(:@tenant_scope_rules)&.delete("DriftItem")
    end
  end

  private

  def capture_warn
    old_stderr = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old_stderr
  end
end
