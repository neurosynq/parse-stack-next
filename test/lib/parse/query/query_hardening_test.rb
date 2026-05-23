require_relative "../../../test_helper"

# Regression tests for Query hardening:
#   * `distinct`/`group_by` forward auth kwargs (session_token/master/acl_user/acl_role)
#     when auto-routing to the mongo-direct path.
#   * `within_polygon` with a `Parse::Polygon` literal emits the legacy
#     GeoPoint-array shape Parse Server accepts.
#   * `__`-prefixed SDK-internal routing markers are stripped from
#     compiled REST/JSON output, regardless of nesting depth.
#   * `scope_to_role` normalizes Symbol input to String before the
#     downstream resolver sees it.
class QueryHardeningTest < Minitest::Test
  # ----------------------------------------------------------------
  # `__`-prefixed routing markers must NOT leak into compiled REST
  # JSON, regardless of how deeply nested.
  # ----------------------------------------------------------------

  def test_compile_where_strips_top_level_marker
    poly = Parse::Polygon.new([[0.0, 0.0], [0.0, 1.0], [1.0, 0.0]])
    q = User.query(:area.geo_intersects => poly)
    compiled = q.compile_where
    refute compiled.key?("__mongo_direct_only"),
           "compile_where must strip the top-level __mongo_direct_only marker"
    refute compiled.key?("__aggregation_pipeline")
  end

  def test_compile_markers_preserves_top_level_marker
    poly = Parse::Polygon.new([[0.0, 0.0], [0.0, 1.0], [1.0, 0.0]])
    q = User.query(:area.geo_intersects => poly)
    markers = q.compile_markers
    assert markers.key?("__mongo_direct_only"),
           "compile_markers must retain the marker for the routing layer"
  end

  def test_compile_does_not_emit_markers_into_rest_payload
    poly = Parse::Polygon.new([[0.0, 0.0], [0.0, 1.0], [1.0, 0.0]])
    q = User.query(:area.geo_intersects => poly)
    payload = q.compile(encode: false)
    refute_includes payload.to_json, "__mongo_direct_only",
                    "Compiled query payload must not contain the routing marker"
    refute_includes payload.to_json, "__aggregation_pipeline"
  end

  def test_marker_in_subquery_does_not_leak_through_matches
    # Outer query is plain REST; inner query carries a direct-only
    # constraint. The outer query's compiled JSON must not include the
    # inner's __ marker.
    inner = User.query(:area.geo_intersects => Parse::Polygon.new([[0, 0], [0, 1], [1, 0]]))
    outer = User.query(:related.matches => inner)
    payload = outer.compile(encode: false)
    refute_includes payload.to_json, "__mongo_direct_only",
                    "Nested subquery must not leak the routing marker into REST JSON"
  end

  def test_requires_mongo_direct_still_fires_after_strip
    # The marker is gone from compile_where but the routing predicate
    # must still detect it via compile_markers.
    poly = Parse::Polygon.new([[0.0, 0.0], [0.0, 1.0], [1.0, 0.0]])
    q = User.query(:area.geo_intersects => poly)
    assert q.requires_mongo_direct?,
           "requires_mongo_direct? must still detect the marker post-strip"
  end

  # ----------------------------------------------------------------
  # `within_polygon` with a `Parse::Polygon` literal must compile to
  # the legacy GeoPoint-array `$polygon` operand Parse Server accepts.
  # ----------------------------------------------------------------

  def test_within_polygon_with_polygon_literal_emits_geopoint_array
    poly = Parse::Polygon.new([[10.0, 20.0], [30.0, 40.0], [50.0, 60.0]])
    compiled = User.query(:location.within_polygon => poly).compile_where["location"]
    inner = compiled[:$geoWithin][:$polygon]
    assert_kind_of Array, inner
    assert_equal inner.length, 3
    inner.each do |hash|
      assert_equal hash[:__type], "GeoPoint"
      assert hash.key?(:latitude)
      assert hash.key?(:longitude)
    end
  end

  def test_within_polygon_literal_does_not_set_mongo_direct_marker
    # The polygon-literal path goes through Parse Server REST cleanly —
    # no need to auto-route to mongo-direct.
    poly = Parse::Polygon.new([[10.0, 20.0], [30.0, 40.0], [50.0, 60.0]])
    q = User.query(:location.within_polygon => poly)
    refute q.requires_mongo_direct?,
           "within_polygon with Polygon literal should not auto-route to mongo-direct"
  end

  # ----------------------------------------------------------------
  # `scope_to_role` Symbol normalization.
  # ----------------------------------------------------------------

  def test_scope_to_role_normalizes_symbol_to_string
    q = User.query
    q.scope_to_role(:admin)
    assert_equal q.acl_role, "admin",
                 "scope_to_role(Symbol) must normalize to String at the boundary"
  end

  def test_scope_to_role_preserves_string
    q = User.query
    q.scope_to_role("scope:reporting")
    assert_equal q.acl_role, "scope:reporting"
  end

  def test_scope_to_role_preserves_role_object
    role = Parse::Role.new(name: "Admin")
    q = User.query
    q.scope_to_role(role)
    assert_same q.acl_role, role
  end

  def test_scope_to_role_acl_user_kwarg_kept_distinct
    # mongo_direct_auth_kwargs picks scope_to_role over master:true
    # when acl_role is set.
    q = User.query
    q.scope_to_role(:admin)
    kwargs = q.send(:mongo_direct_auth_kwargs)
    assert_equal kwargs, { acl_role: "admin" }
  end

  # ----------------------------------------------------------------
  # `distinct` must forward auth kwargs when auto-routing to the
  # mongo-direct path.
  # ----------------------------------------------------------------

  def test_distinct_direct_accepts_auth_kwargs
    # Direct-construction sanity check — the method now accepts the
    # four auth kwargs and forwards them. We can't actually run it
    # without MongoDB available, but verifying the signature is enough
    # for a unit test.
    sig = Parse::Query.instance_method(:distinct_direct)
    params = sig.parameters.map { |type, name| name }
    assert_includes params, :session_token
    assert_includes params, :master
    assert_includes params, :acl_user
    assert_includes params, :acl_role
  end

  def test_distinct_direct_pointers_accepts_auth_kwargs
    sig = Parse::Query.instance_method(:distinct_direct_pointers)
    params = sig.parameters.map { |type, name| name }
    assert_includes params, :session_token
    assert_includes params, :master
    assert_includes params, :acl_user
    assert_includes params, :acl_role
  end

  def test_distinct_auto_routes_when_constraint_requires_direct
    # Auto-route gate: a query with a direct-only constraint must
    # consult assert_mongo_direct_routable! when #distinct is called.
    poly = Parse::Polygon.new([[0.0, 0.0], [0.0, 1.0], [1.0, 0.0]])
    q = User.query(:area.geo_intersects => poly)
    q.use_master_key = false
    err = assert_raises(Parse::Query::MongoDirectRequired) { q.distinct(:something) }
    assert_match(/master.key|scope_to_user/i, err.message)
  end
end
