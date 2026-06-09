# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Parse Server 8.0 flipped `encodeParseObjectInCloudFunction` to true and 9.0
# removed the opt-out, so a cloud function returning a Parse object now yields a
# `__type`-encoded dictionary. These pin that the SDK decodes those envelopes
# back into Parse::Object / Parse::Pointer (matching every other Parse SDK)
# while leaving plain data and unregistered-class objects untouched.
class TestCloudResultDecode < Minitest::Test
  Resp = Struct.new(:result)

  # A registered class so a full Object envelope decodes losslessly.
  class DecodePost < Parse::Object
    parse_class "DecodePostCRD"
    property :title, :string
  end

  def decode(value)
    Parse._decode_cloud_value(value)
  end

  def test_registered_object_envelope_decodes_to_object
    enc = { "__type" => "Object", "className" => "DecodePostCRD",
            "objectId" => "abc123", "title" => "Hello" }
    obj = decode(enc)
    assert_kind_of DecodePost, obj
    assert_equal "abc123", obj.id
    assert_equal "Hello", obj.title
  end

  def test_pointer_envelope_decodes_to_pointer
    enc = { "__type" => "Pointer", "className" => "GhostClassCRD", "objectId" => "g1" }
    ptr = decode(enc)
    assert_kind_of Parse::Pointer, ptr
    assert_equal "g1", ptr.id
    assert_equal "GhostClassCRD", ptr.parse_class
  end

  def test_unregistered_object_envelope_left_as_hash_no_loss
    # Building an unregistered-class Object would degrade to a field-less
    # Pointer; we must hand back the raw Hash to avoid losing attributes.
    enc = { "__type" => "Object", "className" => "TotallyUnregisteredCRD",
            "objectId" => "x", "foo" => "bar" }
    out = decode(enc)
    assert_kind_of Hash, out
    assert_equal "bar", out["foo"]
  end

  def test_literal_app_data_with_type_key_untouched
    # App data that happens to carry a `__type` value we don't recognize must
    # pass through unchanged.
    data = { "__type" => "invoice", "amount" => 5 }
    assert_equal data, decode(data)
  end

  def test_scalars_unchanged
    assert_equal "hello", decode("hello")
    assert_equal 42, decode(42)
    assert_nil decode(nil)
    assert_equal true, decode(true)
  end

  def test_array_of_objects_decodes_elementwise
    arr = [
      { "__type" => "Object", "className" => "DecodePostCRD", "objectId" => "1", "title" => "A" },
      { "__type" => "Object", "className" => "DecodePostCRD", "objectId" => "2", "title" => "B" },
    ]
    out = decode(arr)
    assert_equal 2, out.size
    assert(out.all? { |o| o.is_a?(DecodePost) })
    assert_equal %w[A B], out.map(&:title)
  end

  def test_nested_object_inside_plain_hash_decodes
    payload = { "count" => 1,
                "post" => { "__type" => "Object", "className" => "DecodePostCRD",
                            "objectId" => "z", "title" => "Nested" } }
    out = decode(payload)
    assert_equal 1, out["count"]
    assert_kind_of DecodePost, out["post"]
    assert_equal "Nested", out["post"].title
  end

  def test_extract_cloud_result_unwraps_and_decodes
    enc = { "__type" => "Object", "className" => "DecodePostCRD",
            "objectId" => "abc123", "title" => "Hello" }
    resp = Resp.new({ "result" => enc })
    obj = Parse._extract_cloud_result(resp)
    assert_kind_of DecodePost, obj
    assert_equal "Hello", obj.title
  end

  def test_extract_cloud_result_passes_scalar_through
    resp = Resp.new({ "result" => "Hello world!" })
    assert_equal "Hello world!", Parse._extract_cloud_result(resp)
  end

  def test_extract_cloud_result_tolerates_non_hash_body
    resp = Resp.new("raw-string-body")
    assert_equal "raw-string-body", Parse._extract_cloud_result(resp)
  end

  # ---------------------------------------------------------------------------
  # Server-authoritative decode: a cloud __type:"Object" envelope hydrates
  # through the SAME trusted path as every query / fetch result, so server-set
  # credential-shaped keys are PRESERVED rather than stripped. Filtering them
  # here would make cloud results stricter than the rest of the SDK.
  # ---------------------------------------------------------------------------

  def test_user_envelope_preserves_session_token
    # Mirrors a cloud function that returns `request.user`: the resulting
    # Parse::User must keep its server-set sessionToken (trusted-init does not
    # filter PROTECTED_INITIALIZE_KEYS), exactly as a query/fetch would.
    enc = { "__type" => "Object", "className" => "_User",
            "objectId" => "u1", "username" => "alice", "sessionToken" => "r:tok123" }
    user = decode(enc)
    assert_kind_of Parse::User, user
    assert_equal "u1", user.id
    assert_equal "alice", user.username
    assert_equal "r:tok123", user.session_token,
                 "cloud-decoded user must retain its server-set sessionToken (trusted-init)"
  end

  def test_untrusted_new_strips_session_token_unlike_cloud_decode
    # The contrast that justifies leaving cloud decode on the trusted path:
    # untrusted mass-assignment (Klass.new) DROPS the same protected key, so
    # filtering cloud results would diverge from query/fetch hydration.
    user = Parse::User.new("username" => "bob", "sessionToken" => "r:should_strip")
    assert_nil user.session_token,
               "untrusted Parse::User.new must NOT accept a mass-assigned sessionToken"
  end

  def test_extract_cloud_result_preserves_session_token_through_unwrap
    enc = { "__type" => "Object", "className" => "_User",
            "objectId" => "u1", "username" => "alice", "sessionToken" => "r:tok123" }
    user = Parse._extract_cloud_result(Resp.new({ "result" => enc }))
    assert_kind_of Parse::User, user
    assert_equal "r:tok123", user.session_token
  end
end
