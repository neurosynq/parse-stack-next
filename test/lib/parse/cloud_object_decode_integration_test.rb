# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper_integration"

# End-to-end proof that the SDK decodes the `__type`-encoded Parse objects that
# Parse Server 8.0+/9.x return from cloud functions back into Parse::Object.
# Backed by the `echoObject` / `echoObjects` cloud fixtures in test/cloud/main.js.
class CloudObjectDecodeIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  # Registered so decode resolves the className to a concrete class. parse_class
  # is set explicitly because the nested constant's model name would otherwise
  # carry the enclosing namespace and not match the wire className.
  class EchoObjectThing < Parse::Object
    parse_class "EchoObjectThing"
    property :title, :string
  end

  def teardown
    EchoObjectThing.query.results.each { |o| o.destroy rescue nil } rescue nil
    super
  end

  def test_raw_envelope_is_type_object_encoded
    # Pins the assumption the decoder is built on: PS 9.x wraps a returned
    # object as { "__type": "Object", "className": ..., "objectId": ..., ... }.
    raw = Parse.client.call_function("echoObject", { title: "x" }).result["result"]
    assert_equal "Object", raw["__type"]
    assert_equal "EchoObjectThing", raw["className"]
    refute raw["objectId"].to_s.empty?
  end

  def test_cloud_function_returning_object_decodes_to_parse_object
    obj = Parse.call_function("echoObject", { title: "hi" })
    assert_kind_of EchoObjectThing, obj
    assert_equal "hi", obj.title
    refute obj.id.to_s.empty?, "decoded object should carry its objectId"
  end

  def test_cloud_function_returning_array_decodes_elementwise
    arr = Parse.call_function("echoObjects", {})
    assert_kind_of Array, arr
    assert_equal 2, arr.size
    assert(arr.all? { |o| o.is_a?(EchoObjectThing) }, "each array element should decode")
    assert_equal %w[a b].sort, arr.map(&:title).sort
  end
end
