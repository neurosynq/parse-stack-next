# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit tests for the v5.0 vector_visibility DSL and the webhook
# :vector-column redaction. vector_visibility governs whether a class's
# :vector properties are included in as_json by default; the webhook
# payload strips vector columns unless the class is :public.
class VectorVisibilityTest < Minitest::Test
  class VisDefault < Parse::Object
    parse_class "VisDefault"
    property :title, :string
    property :embedding, :vector, dimensions: 3
  end

  class VisPublic < Parse::Object
    parse_class "VisPublic"
    vector_visibility :public
    property :title, :string
    property :embedding, :vector, dimensions: 3
  end

  def vec3 = Parse::Vector.new([1.0, 2.0, 3.0])

  # ----- DSL -----

  def test_default_is_owner_only
    assert_equal :owner_only, VisDefault.vector_visibility
    refute VisDefault.vectors_public_by_default?
  end

  def test_public_mode
    assert_equal :public, VisPublic.vector_visibility
    assert VisPublic.vectors_public_by_default?
  end

  def test_invalid_mode_raises
    assert_raises(ArgumentError) { VisDefault.vector_visibility(:bogus) }
  end

  # ----- as_json default -----

  def test_owner_only_omits_vector_from_as_json
    obj = VisDefault.new(title: "t")
    obj.embedding = vec3
    refute obj.as_json.key?("embedding")
  end

  def test_public_includes_vector_in_as_json
    obj = VisPublic.new(title: "t")
    obj.embedding = vec3
    assert obj.as_json.key?("embedding")
  end

  def test_explicit_include_vectors_overrides_class_default_both_ways
    d = VisDefault.new(title: "t"); d.embedding = vec3
    p = VisPublic.new(title: "t"); p.embedding = vec3
    assert d.as_json(include_vectors: true).key?("embedding")
    refute p.as_json(include_vectors: false).key?("embedding")
  end

  # ----- webhook redaction -----

  P = Parse::Webhooks::Payload

  def test_webhook_strips_vector_for_owner_only_class
    out = P.scrub_vector_columns({ "className" => "VisDefault", "title" => "x", "embedding" => [1.0, 2.0, 3.0] })
    refute out.key?("embedding")
    assert_equal "x", out["title"]
  end

  def test_webhook_keeps_vector_for_public_class
    out = P.scrub_vector_columns({ "className" => "VisPublic", "title" => "x", "embedding" => [1.0, 2.0, 3.0] })
    assert out.key?("embedding")
  end

  def test_webhook_unknown_class_passes_through
    out = P.scrub_vector_columns({ "className" => "TotallyUnregistered", "embedding" => [1.0] })
    assert out.key?("embedding")
  end

  def test_webhook_non_hash_passes_through
    assert_nil P.scrub_vector_columns(nil)
    assert_equal "x", P.scrub_vector_columns("x")
  end

  def test_webhook_strips_update_payload_via_explicit_klass
    # An update/changes payload carries no className; the resolved class is
    # passed explicitly so its vector columns are still stripped.
    out = P.scrub_vector_columns({ "embedding" => [1.0, 2.0, 3.0], "title" => "x" }, VisDefault)
    refute out.key?("embedding")
  end

  # ----- afterFind objects redaction (Payload constructor path) -----
  #
  # Parse Server's afterFind payload carries NO className anywhere — the matched
  # objects omit it and there is no top-level className (verified against Parse
  # Server 9.9.0). The class is known only from the webhook URL path, threaded
  # in as `webhook_class:`. These fixtures therefore use objects WITHOUT
  # className and supply the class via webhook_class (the real shape), NOT via
  # per-element className.

  def test_webhook_strips_vectors_from_afterfind_objects_via_route_class
    payload = P.new(
      { trigger_name: "afterFind",
        objects: [
          { "title" => "a", "embedding" => [1.0, 2.0, 3.0] },
          { "title" => "b", "embedding" => [4.0, 5.0, 6.0] },
        ] },
      "VisDefault",
    )
    payload.objects.each do |o|
      refute o.key?("embedding"), "afterFind object must have its :vector stripped via the route class"
      assert o.key?("title")
    end
  end

  def test_webhook_afterfind_keeps_vectors_for_public_route_class
    payload = P.new(
      { trigger_name: "afterFind",
        objects: [{ "title" => "a", "embedding" => [1.0, 2.0, 3.0] }] },
      "VisPublic",
    )
    assert payload.objects[0].key?("embedding")
  end

  def test_webhook_afterfind_without_route_class_cannot_scrub
    # Honest negative: with no webhook_class and no per-element className there
    # is no way to resolve the class, so vectors are NOT stripped (fail-open).
    # This pins WHY threading the route class is required.
    payload = P.new(
      trigger_name: "afterFind",
      objects: [{ "title" => "a", "embedding" => [1.0, 2.0, 3.0] }],
    )
    assert payload.objects[0].key?("embedding"),
           "without a resolvable class the vector cannot be stripped (documents the gap the route class closes)"
  end

  def test_webhook_class_sets_parse_class_for_find_trigger
    payload = P.new({ trigger_name: "afterFind", objects: [] }, "VisDefault")
    assert_equal "VisDefault", payload.parse_class,
                 "find triggers resolve parse_class from the route-derived webhook_class"
  end
end
