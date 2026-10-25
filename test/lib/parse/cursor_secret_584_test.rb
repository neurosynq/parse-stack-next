# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Signing secrets for Parse::Cursor must be Strings long enough that the
# signature cannot be forged by guessing the key; unsigned state is accepted
# without a warning only when the caller marks it as trusted persistence.
class CursorSecret584Test < Minitest::Test
  class CursorSecretPost < Parse::Object
    parse_class "CursorSecretPost"
    property :category, :string
  end

  GOOD_SECRET = "k" * Parse::Cursor::MIN_SECRET_BYTES

  def setup
    Parse::Cursor.signing_secret = nil
    Parse::Cursor.reset_unsigned_warning!
  end

  def teardown
    Parse::Cursor.signing_secret = nil
  end

  def cursor
    Parse::Cursor.new(CursorSecretPost.query(category: "news"), limit: 5)
  end

  def test_blank_short_and_non_string_secrets_are_refused
    ["", "   ", "short", :symbol_secret, 12_345, "x" * (Parse::Cursor::MIN_SECRET_BYTES - 1)].each do |bad|
      assert_raises(ArgumentError, bad.inspect) { cursor.serialize(secret: bad) }
      assert_raises(ArgumentError, bad.inspect) { Parse::Cursor.signing_secret = bad }
    end
  end

  def test_blank_secret_cannot_verify_a_token
    token = cursor.serialize(secret: GOOD_SECRET)
    assert_raises(ArgumentError) { Parse::Cursor.deserialize(token, secret: "") }
  end

  def test_valid_secret_round_trips
    token = cursor.serialize(secret: GOOD_SECRET)
    restored = Parse::Cursor.deserialize(token, secret: GOOD_SECRET, expected_class: CursorSecretPost)
    assert_equal "CursorSecretPost", restored.query.table
  end

  def test_trusted_unsigned_state_loads_without_warning
    token = cursor.serialize
    _out, err = capture_io { Parse::Cursor.deserialize(token, trusted: true) }
    assert_empty err
    _out, err = capture_io { Parse::Cursor.deserialize(token) }
    assert_match(/unsigned cursor/, err)
  end

  # `trusted:` only affects unsigned state when no secret is in effect. With a
  # secret configured, signature verification still decides.
  def test_trusted_flag_cannot_bypass_a_configured_secret
    Parse::Cursor.signing_secret = GOOD_SECRET
    unsigned = cursor.serialize(secret: nil)
    assert_raises(ArgumentError) { Parse::Cursor.deserialize(unsigned, trusted: true) }

    signed = JSON.parse(cursor.serialize)
    tampered = JSON.parse(signed["state"])
    tampered["class_name"] = "_Session"
    signed["state"] = JSON.generate(tampered)
    assert_raises(ArgumentError) { Parse::Cursor.deserialize(JSON.generate(signed), trusted: true) }

    other = cursor.serialize(secret: "z" * Parse::Cursor::MIN_SECRET_BYTES)
    assert_raises(ArgumentError) { Parse::Cursor.deserialize(other, trusted: true) }

    assert Parse::Cursor.deserialize(cursor.serialize, trusted: true)
  end

  def test_trusted_flag_cannot_bypass_an_explicit_secret
    unsigned = cursor.serialize
    assert_raises(ArgumentError) do
      Parse::Cursor.deserialize(unsigned, secret: GOOD_SECRET, trusted: true)
    end
  end
end
