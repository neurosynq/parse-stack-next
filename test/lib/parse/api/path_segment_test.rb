require_relative "../../../test_helper"

class PathSegmentTest < Minitest::Test
  PS = Parse::API::PathSegment

  # identifier! — Parse class / function / job names

  def test_identifier_accepts_simple_name
    assert_equal "myFunction", PS.identifier!("myFunction")
  end

  def test_identifier_accepts_leading_underscore_system_class
    assert_equal "_User", PS.identifier!("_User")
    assert_equal "_Role", PS.identifier!("_Role")
    assert_equal "_Session", PS.identifier!("_Session")
  end

  def test_identifier_accepts_alphanumeric_and_underscore
    assert_equal "Song_v2_2024", PS.identifier!("Song_v2_2024")
  end

  def test_identifier_rejects_empty
    assert_raises(ArgumentError) { PS.identifier!("") }
    assert_raises(ArgumentError) { PS.identifier!(nil) }
  end

  def test_identifier_rejects_slash
    assert_raises(ArgumentError) { PS.identifier!("../classes/_User") }
    assert_raises(ArgumentError) { PS.identifier!("foo/bar") }
  end

  def test_identifier_rejects_dot
    assert_raises(ArgumentError) { PS.identifier!("..") }
    assert_raises(ArgumentError) { PS.identifier!("Class.Name") }
  end

  def test_identifier_rejects_query_string
    assert_raises(ArgumentError) { PS.identifier!("name?where=foo") }
    assert_raises(ArgumentError) { PS.identifier!("name&master=1") }
  end

  def test_identifier_rejects_leading_digit
    assert_raises(ArgumentError) { PS.identifier!("9names") }
  end

  def test_identifier_rejects_spaces
    assert_raises(ArgumentError) { PS.identifier!("my function") }
  end

  def test_identifier_rejects_unicode_lookalikes
    # Cyrillic 'а' (U+0430) is not allowed
    assert_raises(ArgumentError) { PS.identifier!("\u0430User") }
  end

  def test_identifier_error_message_includes_kind
    err = assert_raises(ArgumentError) { PS.identifier!("bad/name", kind: "function name") }
    assert_match(/function name/, err.message)
  end

  # file! — Parse file names (looser)

  def test_file_encodes_normal_filename
    result = PS.file!("image_abc123.jpg")
    assert_equal "image_abc123.jpg", result
  end

  def test_file_percent_encodes_spaces
    result = PS.file!("my file.jpg")
    assert_equal "my+file.jpg", result
  end

  def test_file_rejects_slash
    assert_raises(ArgumentError) { PS.file!("../etc/passwd") }
    assert_raises(ArgumentError) { PS.file!("path/to/file.jpg") }
  end

  def test_file_rejects_traversal_tokens
    assert_raises(ArgumentError) { PS.file!("..") }
    assert_raises(ArgumentError) { PS.file!(".") }
  end

  def test_file_rejects_control_chars
    assert_raises(ArgumentError) { PS.file!("name\x00.jpg") }
    assert_raises(ArgumentError) { PS.file!("name\n.jpg") }
  end

  def test_file_rejects_empty
    assert_raises(ArgumentError) { PS.file!("") }
  end
end
