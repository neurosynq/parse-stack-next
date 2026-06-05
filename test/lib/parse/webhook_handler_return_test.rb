require_relative "../../test_helper"
require "minitest/autorun"

# Verifies the value-returning semantics of registered webhook handler blocks.
#
# Handlers run with `self` bound to the Payload, so a block can use an explicit
# `return value` (the natural Ruby idiom) AND the historical proc idioms --
# last-expression value, `next value`, `break value` -- and they all produce the
# handler result. `raise` must still propagate untouched so before_save
# rejections / `error!` keep working.
class WebhookHandlerReturnTest < Minitest::Test
  class HandlerReturnObject < Parse::Object
    property :name
    def autofetch!(*args); end
  end

  def setup
    Parse::Webhooks.instance_variable_set(:@routes, nil)
    Parse.setup(server_url: "https://test.parse.com", application_id: "test", api_key: "test")
  end

  def teardown
    Parse::Webhooks.instance_variable_set(:@routes, nil)
  end

  def function_payload(name, params = {})
    Parse::Webhooks::Payload.new(
      "functionName" => name,
      "params" => params,
    )
  end

  def call_fn(name, params = {})
    Parse::Webhooks.call_route(:function, name, function_payload(name, params))
  end

  def test_explicit_return_value_is_used
    Parse::Webhooks.route(:function, "withReturn") do
      return "early-#{params["who"]}" if params["who"]
      "late"
    end

    assert_equal "early-bob", call_fn("withReturn", "who" => "bob")
    assert_equal "late",      call_fn("withReturn")
  end

  def test_return_can_short_circuit_before_later_work
    Parse::Webhooks.route(:function, "guard") do
      return { error: "denied" } unless params["allowed"]
      { ok: true }
    end

    assert_equal({ error: "denied" }, call_fn("guard"))
    assert_equal({ ok: true },        call_fn("guard", "allowed" => true))
  end

  def test_legacy_last_expression_value_still_works
    Parse::Webhooks.route(:function, "lastExpr") { "the-result" }
    assert_equal "the-result", call_fn("lastExpr")
  end

  def test_legacy_next_value_still_works
    Parse::Webhooks.route(:function, "nextVal") do
      next "via-next" if params["short"]
      "via-last"
    end

    assert_equal "via-next", call_fn("nextVal", "short" => true)
    assert_equal "via-last", call_fn("nextVal")
  end

  def test_self_is_payload_inside_handler
    Parse::Webhooks.route(:function, "selfCheck") do
      return params["echo"]
    end

    assert_equal "hi", call_fn("selfCheck", "echo" => "hi")
  end

  def test_block_with_explicit_payload_param_still_receives_payload
    Parse::Webhooks.route(:function, "argBlock") do |payload|
      return payload.params["v"]
    end

    assert_equal 42, call_fn("argBlock", "v" => 42)
  end

  def test_raise_propagates_unchanged
    Parse::Webhooks.route(:function, "boom") do
      raise Parse::Webhooks::ResponseError, "nope"
    end

    err = assert_raises(Parse::Webhooks::ResponseError) { call_fn("boom") }
    assert_equal "nope", err.message
  end

  def test_error_bang_helper_still_throws
    Parse::Webhooks.route(:function, "errBang") do
      error! "rejected" unless params["ok"]
      "passed"
    end

    err = assert_raises(Parse::Webhooks::ResponseError) { call_fn("errBang") }
    assert_equal "rejected", err.message
    assert_equal "passed", call_fn("errBang", "ok" => true)
  end

  def test_handler_leaves_no_singleton_method_on_payload
    Parse::Webhooks.route(:function, "leakCheck") { return "ok" }
    payload = function_payload("leakCheck")
    Parse::Webhooks.call_route(:function, "leakCheck", payload)

    leaked = payload.singleton_class.instance_methods(false).grep(/parse_webhook_handler/)
    assert_empty leaked, "handler singleton method should be removed after invocation"
  end

  def test_singleton_method_removed_even_when_handler_raises
    Parse::Webhooks.route(:function, "raiseClean") { error! "x" }
    payload = function_payload("raiseClean")
    assert_raises(Parse::Webhooks::ResponseError) do
      Parse::Webhooks.call_route(:function, "raiseClean", payload)
    end

    leaked = payload.singleton_class.instance_methods(false).grep(/parse_webhook_handler/)
    assert_empty leaked, "singleton method must be removed even when the handler raises"
  end

  def test_block_with_extra_required_param_does_not_raise
    # instance_exec(payload, &block) used to leave surplus params nil; the
    # singleton-method invocation must preserve that leniency rather than raise
    # ArgumentError for an arity >= 2 block.
    Parse::Webhooks.route(:function, "twoArg") do |payload, extra|
      return "p=#{payload.params["v"]} extra=#{extra.inspect}"
    end

    assert_equal 'p=1 extra=nil', call_fn("twoArg", "v" => 1)
  end

  def test_before_save_return_false_halts_save
    Parse::Webhooks.route(:before_save, "HandlerReturnObject") do
      return false
    end

    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "object" => { "className" => "HandlerReturnObject", "objectId" => "x1", "name" => "n" },
    )

    assert_raises(Parse::Webhooks::ResponseError) do
      Parse::Webhooks.call_route(:before_save, "HandlerReturnObject", payload)
    end
  end
end
