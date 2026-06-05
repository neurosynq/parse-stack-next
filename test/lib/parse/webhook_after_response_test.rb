require_relative "../../test_helper"
require "minitest/autorun"
require "stringio"

# Verifies Parse::Webhooks::Payload#after_response (alias #defer): work
# registered by a handler runs AFTER the response is produced, off the
# client's critical path. Under a server exposing `rack.after_reply` the runner
# is enqueued there (Puma/Unicorn); otherwise it falls back to a thread.
class WebhookAfterResponseTest < Minitest::Test
  WEBHOOK_HEADER = "HTTP_X_PARSE_WEBHOOK_KEY"

  class AfterRespProbe < Parse::Object
    parse_class "AfterRespProbe"
    property :title, :string
  end

  def setup
    @saved_allow = Parse::Webhooks.instance_variable_get(:@allow_unauthenticated)
    @saved_logging = Parse::Webhooks.logging
    Parse::Webhooks.instance_variable_set(:@key, nil)
    Parse::Webhooks.instance_variable_set(:@allow_unauthenticated, true)
    Parse::Webhooks.logging = false
    Parse::Webhooks.instance_variable_set(:@routes, nil)
    Parse::Webhooks::ReplayProtection.reset!
    Parse.setup(server_url: "https://test.parse.com", application_id: "test", api_key: "test")
  end

  def teardown
    Parse::Webhooks.instance_variable_set(:@allow_unauthenticated, @saved_allow)
    Parse::Webhooks.logging = @saved_logging
    Parse::Webhooks.instance_variable_set(:@routes, nil)
  end

  # env with a Puma/Unicorn-style rack.after_reply array unless after_reply: nil
  def build_env(body:, path: nil, after_reply: [])
    env = {
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE" => "application/json",
      "rack.input" => StringIO.new(body),
      "CONTENT_LENGTH" => body.bytesize.to_s,
    }
    env["PATH_INFO"] = path if path
    env["rack.after_reply"] = after_reply unless after_reply.nil?
    env
  end

  def fn_body(name, params = {})
    { "functionName" => name, "params" => params }.to_json
  end

  def drain(after_reply)
    after_reply.each(&:call)
  end

  def test_after_response_runs_via_rack_after_reply
    ran = []
    Parse::Webhooks.route(:function, "deferFn") do
      after_response { ran << "did-work" }
      "ok"
    end

    after_reply = []
    status, _h, body = Parse::Webhooks.call(build_env(body: fn_body("deferFn"), after_reply: after_reply))

    assert_equal 200, status
    assert_equal({ "success" => "ok" }, JSON.parse(body.join))
    # Not yet run — only enqueued onto rack.after_reply.
    assert_empty ran, "deferred work must not run before the reply is flushed"
    assert_equal 1, after_reply.size

    drain(after_reply)
    assert_equal ["did-work"], ran
  end

  def test_defer_alias_works
    ran = []
    Parse::Webhooks.route(:function, "deferAlias") do
      defer { ran << "via-defer" }
      "ok"
    end
    after_reply = []
    Parse::Webhooks.call(build_env(body: fn_body("deferAlias"), after_reply: after_reply))
    drain(after_reply)
    assert_equal ["via-defer"], ran
  end

  def test_self_inside_deferred_block_is_payload
    seen = []
    Parse::Webhooks.route(:function, "deferSelf") do
      after_response { seen << params["echo"] }
      "ok"
    end
    after_reply = []
    Parse::Webhooks.call(build_env(body: fn_body("deferSelf", "echo" => "hi"), after_reply: after_reply))
    drain(after_reply)
    assert_equal ["hi"], seen
  end

  def test_multiple_deferred_blocks_run_in_order_and_are_isolated
    ran = []
    Parse::Webhooks.route(:function, "deferMany") do
      after_response { ran << 1 }
      after_response { raise "boom" }   # must not abort the others
      after_response { ran << 3 }
      "ok"
    end
    after_reply = []
    Parse::Webhooks.call(build_env(body: fn_body("deferMany"), after_reply: after_reply))
    # A single runner is enqueued; draining it must not raise.
    assert_equal 1, after_reply.size
    drain(after_reply)
    assert_equal [1, 3], ran
  end

  def test_falls_back_to_thread_without_rack_after_reply
    q = Queue.new
    Parse::Webhooks.route(:function, "deferThread") do
      after_response { q << "threaded" }
      "ok"
    end
    # after_reply: nil => no rack.after_reply key => Thread fallback path
    status, _h, _b = Parse::Webhooks.call(build_env(body: fn_body("deferThread"), after_reply: nil))
    assert_equal 200, status
    assert_equal "threaded", q.pop  # blocks until the detached thread runs it
  end

  def test_not_dispatched_when_handler_rejects
    ran = []
    Parse::Webhooks.route(:function, "deferReject") do
      after_response { ran << "should-not-run" }
      error! "nope"
    end
    after_reply = []
    status, _h, body = Parse::Webhooks.call(build_env(body: fn_body("deferReject"), after_reply: after_reply))
    assert_equal 200, status
    assert_equal "nope", JSON.parse(body.join)["error"]
    assert_empty after_reply, "rejected handler must not enqueue deferred work"
    assert_empty ran
  end

  def test_after_response_on_after_save_trigger_path
    # The advertised use case: defer reindex-style work from an after_save
    # trigger. Exercises call!'s trigger branch (which calls call_route twice
    # — the specific class and the "*" route — on the SAME payload), so this
    # also guards that dispatch happens once, not once per call_route.
    ran = []
    Parse::Webhooks.route(:after_save, "AfterRespProbe") do
      post = parse_object
      after_response { ran << post.id }
      post
    end

    body = JSON.generate("triggerName" => "afterSave",
                         "object" => { "className" => "AfterRespProbe", "objectId" => "p1" })
    after_reply = []
    status, _h, _b = Parse::Webhooks.call(
      build_env(body: body, path: "/after_save/AfterRespProbe", after_reply: after_reply)
    )

    assert_equal 200, status
    assert_equal 1, after_reply.size, "exactly one runner enqueued despite specific + '*' routing"
    assert_empty ran
    drain(after_reply)
    assert_equal ["p1"], ran
  end

  def test_no_after_response_means_no_runner_enqueued
    Parse::Webhooks.route(:function, "plain") { "ok" }
    after_reply = []
    Parse::Webhooks.call(build_env(body: fn_body("plain"), after_reply: after_reply))
    assert_empty after_reply
  end
end
