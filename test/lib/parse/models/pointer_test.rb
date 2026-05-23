require_relative "../../../test_helper"

class TestPointer < Minitest::Test
  def setup
    @id = "theObjectId"
    @theClass = "_User"
    @pointer = Parse::Pointer.new(@theClass, @id)
  end

  def test_base_fields
    pointer = @pointer
    assert_equal Parse::Model::TYPE_POINTER, "Pointer"
    assert_respond_to pointer, :__type
    assert_equal pointer.__type, Parse::Model::TYPE_POINTER
    assert_respond_to pointer, :id
    assert_respond_to pointer, :objectId
    assert_equal pointer.id, @id
    assert_equal pointer.id, pointer.objectId

    assert_respond_to pointer, :className
    assert_respond_to pointer, :parse_class
    assert_equal pointer.parse_class, @theClass
    assert_equal pointer.parse_class, pointer.className
    assert pointer.pointer?
    refute pointer.fetched?
    # Create a new pointer from this pointer. They should still be equal.
    assert pointer == pointer.pointer
    assert pointer.present?
  end

  def test_json
    assert_equal @pointer.as_json, { :__type => Parse::Model::TYPE_POINTER, className: @theClass, objectId: @id }.as_json
  end

  def test_sig
    assert_equal @pointer.sig, "#{@theClass}##{@id}"
  end

  def test_array_objectIds
    assert_equal [@pointer.id], [@pointer].objectIds
    assert_equal [@pointer.id], [@pointer, 4, "junk", nil].objectIds
    assert_equal [], [4, "junk", nil].objectIds
  end

  def test_array_valid_parse_objects
    assert_equal [@pointer], [@pointer].valid_parse_objects
    assert_equal [@pointer], [@pointer, 4, "junk", nil].valid_parse_objects
    assert_equal [], [4, "junk", nil].valid_parse_objects
  end

  def test_array_parse_pointers
    assert_equal [@pointer], [@pointer].parse_pointers
    assert_equal [@pointer, @pointer], [@pointer, { className: "_User", objectId: @id }].parse_pointers
    assert_equal [@pointer, @pointer], [@pointer, { "className" => "_User", "objectId" => @id }].parse_pointers
    assert_equal [@pointer, @pointer], [nil, 4, "junk", { className: "_User", objectId: @id }, { "className" => "_User", "objectId" => @id }].parse_pointers
  end

  def test_id_validation_accepts_alphanumeric
    %w[abc 0123456789 abcDEF123 X aBcD1234efGH].each do |oid|
      pointer = Parse::Pointer.new("Song", oid)
      assert_equal oid, pointer.id
    end
  end

  def test_id_validation_accepts_nil_and_empty
    pointer = Parse::Pointer.new("Song", nil)
    assert_nil pointer.id

    pointer = Parse::Pointer.new("Song", "")
    assert_equal "", pointer.id
    refute pointer.present?
  end

  def test_id_setter_rejects_traversal_payloads
    pointer = Parse::Pointer.new("Song", "abc123")
    %w[
      ../etc/passwd
      foo/bar
      foo\\bar
      a?b=c
      foo&bar
      foo;rm
      foo%20bar
      "quoted"
      foo'bar
      foo\nbar
      foo\rbar
      "><script>
    ].each do |payload|
      assert_raises(ArgumentError, "should reject #{payload.inspect}") do
        pointer.id = payload
      end
    end
  end

  def test_id_setter_rejects_overlong_value
    pointer = Parse::Pointer.new("Song", "abc123")
    assert_raises(ArgumentError) { pointer.id = "a" * 65 }
  end

  def test_id_setter_accepts_custom_objectid_separators
    %w[user_abc role-test object.id u_aBc-1.2].each do |oid|
      pointer = Parse::Pointer.new("Song", oid)
      assert_equal oid, pointer.id, "should accept #{oid.inspect}"
    end
  end

  def test_id_setter_accepts_subsequent_valid_assignment
    pointer = Parse::Pointer.new("Song", "abc123")
    pointer.id = "xyz789ABC0"
    assert_equal "xyz789ABC0", pointer.id
  end

  def test_initialize_rejects_invalid_objectid
    assert_raises(ArgumentError) { Parse::Pointer.new("Song", "../etc/passwd") }
  end
end
