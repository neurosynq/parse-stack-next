# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Unit tests for {Parse::Client::DuplicateValueError} — the typed exception
# raised when a Parse Server response carries code 137 (DuplicateValue).
#
# The constructor MUST redact MongoDB `keyValue:` fragments from the
# exception message so the offending unique-constraint value (email,
# username, external ID) never leaks into application logs. The raw
# response stays on `#response` for the synchronize-create wrapper and
# other internal callers that legitimately need the unredacted detail.
class DuplicateValueErrorTest < Minitest::Test
  # Stand-in for {Parse::Response} — we only exercise the
  # `respond_to?(:error)` branch of the constructor.
  Stub = Struct.new(:error, :code) do
    def to_s; error.to_s; end
  end

  # The MongoDB driver's serialized DuplicateKey message includes the
  # offending unique-key payload in BOTH `keyValue: { ... }` AND
  # `dup key: { ... }` form. The redactor must strip both so the
  # colliding identifier (here, the email) does not surface in
  # application logs via either fragment.
  def test_redacts_keyvalue_fragment_with_user_email
    msg = 'E11000 duplicate key error collection: parse_app._User index: email_1 dup key: { : "victim@example.com" } keyValue: { "email": "victim@example.com" }'
    err = Parse::Client::DuplicateValueError.new(Stub.new(msg, 137))
    refute_includes err.message, "victim@example.com",
                    "neither keyValue nor dup-key payload may leak into exception message"
    assert_includes err.message, "[REDACTED]",
                    "redaction marker must be visible so operators know data was stripped"
    refute_match(/keyValue:?\s*\{[^}]*\}/, err.message,
                 "no keyValue: { ... } fragment should survive redaction")
    refute_match(/dup\s*key\s*:?\s*\{[^}]*\}/i, err.message,
                 "no dup key: { ... } fragment should survive redaction")
  end

  # Verify the parenthesized `keyValue: { ... }` is removed regardless of
  # spacing / colon variants the driver / Parse Server combinations emit.
  def test_redacts_keyvalue_without_colon_and_with_extra_spaces
    cases = [
      'keyValue { "email": "x@y.com" }',
      'keyValue:{"email":"x@y.com"}',
      'keyValue:    { email: "x@y.com", username: "x" }',
    ]
    cases.each do |raw|
      err = Parse::Client::DuplicateValueError.new(Stub.new("duplicate: #{raw}", 137))
      refute_includes err.message, "x@y.com", "keyValue payload variant must be redacted: #{raw.inspect}"
      assert_includes err.message, "[REDACTED]"
    end
  end

  # The #response accessor must preserve the original Parse::Response
  # object so the synchronize-create wrapper can still read response.code
  # to confirm code 137 before re-querying inside the held lock.
  def test_response_accessor_preserves_original_object
    stub = Stub.new("duplicate: keyValue: { email: \"x@y.com\" }", 137)
    err = Parse::Client::DuplicateValueError.new(stub)
    assert_same stub, err.response, "raw response must be preserved on #response for internal callers"
    assert_equal 137, err.response.code
  end

  # String responses (the legacy non-Parse::Response path) must still be
  # accepted and redacted.
  def test_accepts_plain_string_response
    err = Parse::Client::DuplicateValueError.new('keyValue: { "email": "leak@x.com" }')
    refute_includes err.message, "leak@x.com"
    assert_includes err.message, "[REDACTED]"
    # When a String is passed, #response holds that String — callers that
    # need a typed Parse::Response will branch on response_kind, but the
    # accessor MUST exist and not blow up.
    assert_equal 'keyValue: { "email": "leak@x.com" }', err.response
  end

  # Non-MongoDB messages must pass through verbatim — the redactor only
  # touches `keyValue:` fragments. A vanilla "user already exists" string
  # should not be mangled.
  def test_leaves_non_mongo_messages_intact
    msg = "User already exists with this identifier"
    err = Parse::Client::DuplicateValueError.new(Stub.new(msg, 137))
    assert_equal msg, err.message
  end

  # Nil-safe: errors constructed without a response (defensive callers)
  # must not raise.
  def test_handles_nil_response_without_raise
    err = Parse::Client::DuplicateValueError.new(nil)
    refute_nil err.message
    assert_nil err.response
  end

  # CODE constant must remain 137 — the synchronize-create recovery path
  # compares response.code to this constant.
  def test_code_constant_is_137
    assert_equal 137, Parse::Client::DuplicateValueError::CODE
  end

  # Class-level .redact helper is the single redaction implementation;
  # exposing it directly lets other layers reuse the same stripping logic
  # for log lines without instantiating an exception.
  def test_class_level_redact_helper
    raw = 'keyValue: { "email": "x@y.com" }'
    result = Parse::Client::DuplicateValueError.redact(raw)
    refute_includes result, "x@y.com"
    assert_includes result, "[REDACTED]"
    assert_nil Parse::Client::DuplicateValueError.redact(nil)
    assert_equal "no match here", Parse::Client::DuplicateValueError.redact("no match here")
  end

  # Both fragment forms must be redacted independently by the helper.
  def test_class_level_redact_handles_dup_key_form
    raw = 'dup key: { : "secret@x.com" }'
    result = Parse::Client::DuplicateValueError.redact(raw)
    refute_includes result, "secret@x.com"
    assert_includes result, "[REDACTED]"
  end
end
