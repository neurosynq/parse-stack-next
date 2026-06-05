# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Tests for Parse Server context propagation (X-Parse-Cloud-Context header).
#
# Parse Server threads a caller-supplied `context` hash from a REST write or
# cloud-function call through to beforeSave/afterSave cloud triggers via
# req.info.context. The SDK participates on two sides:
#
#   SEND  — create_object / update_object / call_function accept `context:` and
#           serialize it as the X-Parse-Cloud-Context header when present.
#   RECEIVE — Parse::Webhooks::Payload exposes a `#context` accessor populated
#             from the `context` key in the incoming trigger payload hash.
class TestContextPropagation < Minitest::Test

  # ---------------------------------------------------------------------------
  # SEND side — header constant
  # ---------------------------------------------------------------------------

  def test_cloud_context_header_constant_exists
    assert_equal "X-Parse-Cloud-Context", Parse::Protocol::CLOUD_CONTEXT
  end

  # ---------------------------------------------------------------------------
  # SEND side — create_object header-building (exercises real API module logic)
  # ---------------------------------------------------------------------------

  # A minimal class that includes Parse::API::Objects and captures the headers
  # that the method would pass to `request`, without making a network call.
  class FakeObjectsClient
    include Parse::API::Objects

    attr_reader :captured_headers

    # Matches the signature that create_object/update_object call:
    #   request(method, uri, body:, headers:, opts:)
    def request(_method, _uri, body: nil, headers: {}, opts: {})
      @captured_headers = headers
      Parse::Response.new
    end

    # required by uri_path (delegated to self.class via the module)
    def self.uri_path(class_name, id = nil)
      id ? "classes/#{class_name}/#{id}" : "classes/#{class_name}/"
    end

    def uri_path(class_name, id = nil)
      self.class.uri_path(class_name, id)
    end
  end

  def test_create_object_sets_cloud_context_header
    ctx  = { "requestId" => "abc-123", "source" => "test" }
    fake = FakeObjectsClient.new
    fake.create_object("Post", { title: "Hello" }, context: ctx)

    assert_equal ctx.to_json, fake.captured_headers[Parse::Protocol::CLOUD_CONTEXT]
  end

  def test_create_object_omits_cloud_context_header_when_nil
    fake = FakeObjectsClient.new
    fake.create_object("Post", { title: "Hello" })

    refute fake.captured_headers.key?(Parse::Protocol::CLOUD_CONTEXT),
           "X-Parse-Cloud-Context header must be absent when context: is not supplied"
  end

  def test_update_object_sets_cloud_context_header
    ctx  = { "userId" => "u1", "action" => "publish" }
    fake = FakeObjectsClient.new
    fake.update_object("Post", "abc123", { status: "published" }, context: ctx)

    assert_equal ctx.to_json, fake.captured_headers[Parse::Protocol::CLOUD_CONTEXT]
  end

  def test_update_object_omits_cloud_context_header_when_nil
    fake = FakeObjectsClient.new
    fake.update_object("Post", "abc123", { status: "draft" })

    refute fake.captured_headers.key?(Parse::Protocol::CLOUD_CONTEXT),
           "X-Parse-Cloud-Context header must be absent when context: is not supplied"
  end

  # Verify that a caller-owned headers hash is NOT mutated in place — the
  # method must merge into a new hash, not modify the argument.
  def test_create_object_does_not_mutate_caller_headers
    ctx          = { "source" => "test" }
    caller_hdrs  = { "X-Custom" => "yes" }.freeze  # frozen guards mutation
    fake         = FakeObjectsClient.new

    assert_silent { fake.create_object("Post", {}, headers: caller_hdrs, context: ctx) }
    refute caller_hdrs.key?(Parse::Protocol::CLOUD_CONTEXT)
  end

  # ---------------------------------------------------------------------------
  # SEND side — call_function header-building (exercises real API module logic)
  # ---------------------------------------------------------------------------

  class FakeCloudClient
    include Parse::API::CloudFunctions

    attr_reader :captured_headers

    def request(_method, _uri, body: nil, headers: {}, opts: {})
      @captured_headers = headers
      Parse::Response.new
    end
  end

  def test_call_function_sets_cloud_context_header
    ctx  = { "traceId" => "xyz-789" }
    fake = FakeCloudClient.new
    fake.call_function("myFunc", { arg: 1 }, context: ctx)

    assert_equal ctx.to_json, fake.captured_headers[Parse::Protocol::CLOUD_CONTEXT]
  end

  def test_call_function_omits_cloud_context_header_when_nil
    fake = FakeCloudClient.new
    fake.call_function("myFunc", { arg: 1 })

    refute fake.captured_headers.key?(Parse::Protocol::CLOUD_CONTEXT),
           "X-Parse-Cloud-Context header must be absent when context: is not supplied"
  end

  def test_call_function_with_session_sets_cloud_context_header
    ctx  = { "locale" => "en-US" }
    fake = FakeCloudClient.new
    fake.call_function_with_session("myFunc", { arg: 2 }, "sess-token-abc", context: ctx)

    assert_equal ctx.to_json, fake.captured_headers[Parse::Protocol::CLOUD_CONTEXT]
  end

  # ---------------------------------------------------------------------------
  # SEND side — module-level Parse.call_function threads context: to client
  # ---------------------------------------------------------------------------

  def test_parse_call_function_with_context_threads_context_kwarg
    ctx = { "requestId" => "mod-test-01" }

    mock_client   = Minitest::Mock.new
    mock_response = Minitest::Mock.new
    mock_response.expect :error?, false
    mock_response.expect :result, { "result" => "ok" }

    # The module-level Parse.call_function must forward context: to the client
    # method when it is non-nil.
    mock_client.expect :call_function, mock_response,
                       ["ctxFunc", { param: "v" }],
                       opts: {}, context: ctx

    Parse::Client.stub :client, mock_client do
      result = Parse.call_function("ctxFunc", { param: "v" }, context: ctx)
      assert_equal "ok", result
    end

    mock_client.verify
    mock_response.verify
  end

  def test_parse_call_function_without_context_does_not_pass_context_kwarg
    # When context: is absent the call to the client method must carry no
    # context: kwarg — this preserves exact compatibility with the existing
    # mock expectations in cloud_functions_module_test.rb.
    mock_client   = Minitest::Mock.new
    mock_response = Minitest::Mock.new
    mock_response.expect :error?, false
    mock_response.expect :result, { "result" => "plain" }

    mock_client.expect :call_function, mock_response,
                       ["plainFunc", {}],
                       opts: {}

    Parse::Client.stub :client, mock_client do
      result = Parse.call_function("plainFunc", {})
      assert_equal "plain", result
    end

    mock_client.verify
    mock_response.verify
  end

  # ---------------------------------------------------------------------------
  # RECEIVE side — Parse::Webhooks::Payload context accessor
  # ---------------------------------------------------------------------------

  def test_payload_exposes_context_when_present
    ctx = { "requestId" => "r-42", "locale" => "fr-FR" }
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "object"      => { "className" => "Post", "objectId" => "abc1" },
      "master"      => true,
      "context"     => ctx,
    )

    assert_equal ctx, payload.context
  end

  def test_payload_context_is_nil_when_absent
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "afterSave",
      "object"      => { "className" => "Post", "objectId" => "def2" },
      "master"      => true,
    )

    assert_nil payload.context
  end

  def test_payload_context_is_not_in_credentials_scrub
    # Verify context is NOT treated as a credential — its keys must survive
    # intact even if they happen to match other scrubbed key names.
    ctx = { "note" => "session notes are caller metadata, not credentials" }
    payload = Parse::Webhooks::Payload.new(
      "functionName" => "doWork",
      "master"       => false,
      "context"      => ctx,
    )

    assert_equal ctx, payload.context,
                 "context must pass through without credential scrubbing"
  end

  def test_payload_context_appears_in_attributes
    assert Parse::Webhooks::Payload::ATTRIBUTES.key?(:context),
           "context must be listed in ATTRIBUTES so it appears in #as_json"
  end

  def test_payload_context_responds_to_accessor
    payload = Parse::Webhooks::Payload.new({})
    assert_respond_to payload, :context
    assert_respond_to payload, :context=
  end

  def test_payload_function_request_with_context
    ctx = { "source" => "ios", "version" => "2.1" }
    payload = Parse::Webhooks::Payload.new(
      "functionName" => "processPost",
      "params"       => { "postId" => "xyz" },
      "master"       => false,
      "context"      => ctx,
    )

    assert payload.function?
    assert_equal ctx, payload.context
  end
end
