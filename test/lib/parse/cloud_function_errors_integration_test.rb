# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper_integration"

# Model bound to the +ValidatedThing+ class whose beforeSave hook (in
# test/cloud/main.js) rejects a non-positive +amount+. Defined here so the
# save routes to the right collection rather than falling back to the
# abstract +Parse::Object+ base.
class ValidatedThing < Parse::Object
  parse_class "ValidatedThing"
  property :amount, :integer
end

# End-to-end coverage for cloud-function ERROR scenarios against a live
# Parse Server. The happy paths are already pinned in
# +cloud_functions_integration_test.rb+ and
# +client_rest_cloud_function_integration_test.rb+; this file pins how the
# SDK surfaces the failure modes a cloud function can return.
#
# Cloud-code fixtures live in +test/cloud/main.js+ (loaded at server boot
# via the mounted volume — editing them requires a Parse Server restart):
#
#   boomGeneric    -> bare `throw new Error(...)`         => code 141 (SCRIPT_FAILED)
#   boomParseError -> `throw new Parse.Error(102, ...)`   => code 102 (INVALID_QUERY)
#   boomCustomCode -> `throw new Parse.Error(4242, ...)`  => code 4242 (application-defined)
#   maybeBoom      -> succeeds, or throws 142, by param   => both branches
#   ValidatedThing -> beforeSave rejects amount <= 0      => code 142 (VALIDATION_ERROR)
#
# What this pins:
#   1. +Parse.call_function!+ raises +CloudCodeError+ carrying the wire
#      error code, message, and HTTP status — for generic, typed, and
#      application-defined cloud errors alike.
#   2. The non-bang +Parse.call_function+ returns +nil+ (does not raise)
#      on a cloud error, and +raw: true+ returns the errored response.
#   3. A function that conditionally fails reports success and failure
#      cleanly through the SAME name.
#   4. A +beforeSave+ validation rejection propagates to the SDK save path
#      (save returns false; the retained response carries the wire code).
class CloudFunctionErrorsIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  # ---------------------------------------------------------------------
  # call_function! — generic JS throw maps to SCRIPT_FAILED (141).
  # ---------------------------------------------------------------------
  def test_generic_throw_raises_cloud_code_error_with_141
    error = assert_raises(Parse::Error::CloudCodeError) do
      Parse.call_function!("boomGeneric")
    end

    assert_equal "boomGeneric", error.function_name
    assert_equal 141, error.code,
                 "a bare JS throw must surface as SCRIPT_FAILED (141), got #{error.code.inspect}"
    assert_includes error.message, "generic failure from cloud code",
                    "the cloud error message must be preserved on the exception"
  end

  # ---------------------------------------------------------------------
  # call_function! — typed Parse.Error keeps its standard code.
  # ---------------------------------------------------------------------
  def test_typed_parse_error_raises_with_standard_code
    error = assert_raises(Parse::Error::CloudCodeError) do
      Parse.call_function!("boomParseError")
    end

    assert_equal 102, error.code,
                 "a typed Parse.Error(102) must surface its own code, not be collapsed to 141"
    assert_includes error.message, "typed parse error from cloud code"
  end

  # ---------------------------------------------------------------------
  # call_function! — application-defined numeric code is propagated verbatim.
  # This is the load-bearing assertion that the SDK does not normalize or
  # clamp non-standard cloud error codes.
  # ---------------------------------------------------------------------
  def test_custom_error_code_is_propagated_verbatim
    error = assert_raises(Parse::Error::CloudCodeError) do
      Parse.call_function!("boomCustomCode")
    end

    assert_equal 4242, error.code,
                 "an application-defined code (4242) must reach the caller unchanged"
    assert_includes error.message, "custom application error code"
    refute_nil error.response, "CloudCodeError must retain the underlying response for debugging"
  end

  # ---------------------------------------------------------------------
  # Non-bang call_function returns nil (does not raise) on a cloud error.
  # This is the documented contract difference vs. call_function!.
  # ---------------------------------------------------------------------
  def test_non_bang_call_function_returns_nil_on_error
    # The non-bang path emits a "CloudCodeError" warning to stderr on a
    # cloud error (expected noise); the contract under test is the return
    # value, which must be nil rather than a raise or a partial result.
    result = Parse.call_function("boomGeneric")

    assert_nil result,
               "non-bang call_function must return nil (not raise, not a partial value) on a cloud error"
  end

  # ---------------------------------------------------------------------
  # raw: true returns the raw response object, error flags intact, so a
  # caller can inspect code/error without exception handling.
  # ---------------------------------------------------------------------
  def test_raw_returns_errored_response
    response = Parse.call_function("boomCustomCode", {}, raw: true)

    refute_nil response, "raw: true must return the response object even on error"
    assert response.error?, "raw response must report error? on a cloud failure"
    assert_equal 4242, response.code.to_i,
                 "raw response must carry the wire error code"
  end

  # ---------------------------------------------------------------------
  # The same function name reports both success and failure cleanly. The
  # happy branch returns the result hash; the failing branch raises with
  # the VALIDATION_ERROR code (142).
  # ---------------------------------------------------------------------
  def test_conditional_function_success_and_failure_branches
    ok = Parse.call_function!("maybeBoom", { fail: false })
    assert_equal({ "ok" => true }, ok,
                 "happy branch must return the function's result payload")

    error = assert_raises(Parse::Error::CloudCodeError) do
      Parse.call_function!("maybeBoom", { fail: true })
    end
    assert_equal 142, error.code,
                 "failing branch must surface VALIDATION_ERROR (142), got #{error.code.inspect}"
  end

  # ---------------------------------------------------------------------
  # A beforeSave validation rejection propagates to the object save path:
  # save returns false (default raise_on_save_failure is off) and the
  # retained response carries the wire error code/message. This proves the
  # cloud-trigger failure is not swallowed between the wire and the caller.
  # ---------------------------------------------------------------------
  def test_before_save_validation_rejection_propagates_to_save
    obj = ValidatedThing.new(amount: -5)

    refute obj.save,
           "save must return false when a beforeSave hook rejects the write"

    response = obj.instance_variable_get(:@_last_response)
    refute_nil response, "the failing create response must be retained on the object"
    assert response.error?, "retained response must report error?"
    assert_equal 142, response.code.to_i,
                 "beforeSave rejection must surface VALIDATION_ERROR (142) from the wire"
    assert_includes response.error.to_s, "amount must be a positive number",
                    "the cloud validation message must reach the SDK"
  end

  # ---------------------------------------------------------------------
  # Sanity: a VALID ValidatedThing save succeeds, proving the beforeSave
  # hook gates on the business rule rather than rejecting unconditionally.
  # ---------------------------------------------------------------------
  def test_before_save_validation_allows_valid_object
    obj = ValidatedThing.new(amount: 10)

    assert obj.save, "a ValidatedThing with a positive amount must save"
    refute_nil obj.id, "a successful save must assign an objectId"
    @test_context.track(obj) if @test_context
  end
end
