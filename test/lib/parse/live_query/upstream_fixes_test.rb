# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/live_query"

# Coverage for the four upstream-filed LiveQuery items addressed in
# v5.1.0:
# * SubscriptionError carries `request_id` + `class_name` context
#   (auto-prefixed onto `message` for single-line log lines).
# * `Subscription#to_subscribe_message` emits `masterKey` when the
#   subscription was constructed with `use_master_key: true` AND the
#   parent client has a master_key configured.
# * `Query#subscribe` and `Klass.subscribe` accept `use_master_key:`
#   and thread it through.
# * `Parse::LiveQuery.run_until_signal!` installs Signal.trap handlers,
#   blocks until one fires, and shuts the client down cleanly from the
#   main thread (NOT from the trap context — which would ThreadError
#   on macOS).
class LiveQueryUpstreamFixesTest < Minitest::Test
  # ---- SubscriptionError context (item 5) -----------------------------

  def test_subscription_error_with_no_context_preserves_message
    err = Parse::LiveQuery::SubscriptionError.new("Permission denied (code: 101)")
    assert_equal "Permission denied (code: 101)", err.message
    assert_nil err.request_id
    assert_nil err.class_name
  end

  def test_subscription_error_with_context_prefixes_message
    err = Parse::LiveQuery::SubscriptionError.new(
      "Permission denied (code: 101)",
      request_id: 42, class_name: "Post",
    )
    assert_equal 42, err.request_id
    assert_equal "Post", err.class_name
    assert_match(/request_id=42/, err.message)
    assert_match(/class=Post/, err.message)
    assert_match(/Permission denied/, err.message)
  end

  def test_subscription_error_accepts_existing_exception
    inner = RuntimeError.new("wrapped")
    err = Parse::LiveQuery::SubscriptionError.new(inner, request_id: 7)
    assert_match(/request_id=7/, err.message)
    assert_match(/wrapped/, err.message)
  end

  def test_subscription_fail_promotes_string_to_typed_error_with_context
    sub = build_subscription
    captured = nil
    sub.on(:error) { |e| captured = e }

    sub.fail!("Permission denied (code: 101)")

    assert_kind_of Parse::LiveQuery::SubscriptionError, captured
    assert_equal sub.request_id, captured.request_id
    assert_equal "Post", captured.class_name
    assert_match(/request_id=#{sub.request_id}/, captured.message)
    assert_match(/class=Post/, captured.message)
  end

  # ---- use_master_key per-subscription opt-in (item 3) ----------------

  def test_subscription_default_does_not_emit_master_key
    sub = build_subscription
    msg = sub.to_subscribe_message
    refute msg.key?(:masterKey),
      "subscribe frame must not carry masterKey by default"
    refute sub.use_master_key?
  end

  def test_subscription_with_use_master_key_emits_master_key_when_client_has_one
    client = stub_client(master_key: "MK-secret")
    sub = Parse::LiveQuery::Subscription.new(
      client: client, class_name: "Post", query: {}, use_master_key: true,
    )
    msg = sub.to_subscribe_message
    assert_equal "MK-secret", msg[:masterKey]
    assert sub.use_master_key?
  end

  def test_subscription_with_use_master_key_no_op_when_client_lacks_master_key
    # Per-subscription opt-in is silently suppressed when the client
    # wasn't constructed with a master_key — the wire field would be
    # nil/empty and silently downgrade to no auth, which is worse than
    # the kwarg being a no-op.
    client = stub_client(master_key: nil)
    sub = Parse::LiveQuery::Subscription.new(
      client: client, class_name: "Post", query: {}, use_master_key: true,
    )
    msg = sub.to_subscribe_message
    refute msg.key?(:masterKey),
      "masterKey must NOT be emitted when client lacks master_key"
  end

  # Round-3 review tightening: a misconfigured client returning `""`
  # (or any non-String) for `master_key` previously slipped the truthy
  # guard and emitted `masterKey: ""` on the wire — a malformed frame
  # the LiveQuery server may silently reject. The post-fix check
  # requires `master_key` to be a non-empty String.
  def test_subscription_with_empty_string_master_key_does_not_emit_master_key
    client = stub_client(master_key: "")
    sub = Parse::LiveQuery::Subscription.new(
      client: client, class_name: "Post", query: {}, use_master_key: true,
    )
    msg = sub.to_subscribe_message
    refute msg.key?(:masterKey),
      "empty-string master_key must NOT produce masterKey: \"\" on the wire"
  end

  def test_subscription_with_non_string_master_key_does_not_emit_master_key
    # Some test mocks / proxies may return a Symbol or Integer for
    # master_key. The wire contract requires a String; emit nothing
    # rather than `masterKey: 42` or `masterKey: :secret`.
    [42, :secret, true, Object.new].each do |bogus|
      client = stub_client(master_key: bogus)
      sub = Parse::LiveQuery::Subscription.new(
        client: client, class_name: "Post", query: {}, use_master_key: true,
      )
      refute sub.to_subscribe_message.key?(:masterKey),
        "non-String master_key #{bogus.inspect} must NOT be emitted on the wire"
    end
  end

  def test_subscription_with_whitespace_only_master_key_still_emits
    # Whitespace-only `master_key` is allowed (it's a non-empty String).
    # If an operator genuinely configured `master_key = "   "`, that's
    # their misconfiguration to debug; we don't second-guess String
    # content beyond emptiness because legitimate master keys can
    # contain any non-whitespace characters.
    client = stub_client(master_key: "   ")
    sub = Parse::LiveQuery::Subscription.new(
      client: client, class_name: "Post", query: {}, use_master_key: true,
    )
    assert_equal "   ", sub.to_subscribe_message[:masterKey]
  end

  def test_subscription_use_master_key_coerces_non_boolean_to_false
    client = stub_client(master_key: "MK-secret")
    sub = Parse::LiveQuery::Subscription.new(
      client: client, class_name: "Post", query: {}, use_master_key: "yes",
    )
    # String "yes" must not enable master_key auth — only literal true.
    refute sub.use_master_key?
    refute sub.to_subscribe_message.key?(:masterKey)
  end

  def test_subscription_use_master_key_and_session_token_can_coexist
    # The Parse JS client documents that both may be present on a
    # subscribe frame; the server prefers masterKey when set. Our
    # subscription must forward both without dropping either.
    client = stub_client(master_key: "MK-secret")
    sub = Parse::LiveQuery::Subscription.new(
      client: client, class_name: "Post", query: {},
      session_token: "r:abc", use_master_key: true,
    )
    msg = sub.to_subscribe_message
    assert_equal "MK-secret", msg[:masterKey]
    assert_equal "r:abc",     msg[:sessionToken]
  end

  # End-to-end thread-through: Klass.subscribe(...) must propagate
  # use_master_key: to the constructed Subscription object. The plumbing
  # passes through Object#subscribe → Query#subscribe → Client#subscribe
  # → Subscription.new. Without this test, a regression at any layer
  # would compile silently and only fail at the wire-frame check.
  class FakeLiveQueryClient
    attr_reader :master_key, :captured_subscribe

    def initialize(master_key: nil)
      @master_key = master_key
      @captured_subscribe = nil
    end

    # Mirror Client#subscribe's signature so the kwarg propagation is exercised.
    def subscribe(class_name, where: {}, fields: nil, session_token: nil, use_master_key: false)
      sub = Parse::LiveQuery::Subscription.new(
        client: self,
        class_name: class_name.to_s,
        query: where,
        fields: fields,
        session_token: session_token,
        use_master_key: use_master_key,
      )
      @captured_subscribe = sub
      sub
    end
  end

  class FakePost < Parse::Object
    parse_class "FakePostLQTest"
  end

  def test_klass_subscribe_threads_use_master_key_kwarg_through
    fake = FakeLiveQueryClient.new(master_key: "MK-end-to-end")
    sub = FakePost.subscribe(use_master_key: true, client: fake)

    assert sub.use_master_key?, "Klass.subscribe(use_master_key: true) must reach the Subscription"
    msg = sub.to_subscribe_message
    assert_equal "MK-end-to-end", msg[:masterKey],
      "wire envelope must carry masterKey when the kwarg is set end-to-end"
  end

  def test_klass_subscribe_default_does_not_carry_master_key
    fake = FakeLiveQueryClient.new(master_key: "MK-end-to-end")
    sub = FakePost.subscribe(client: fake)
    refute sub.use_master_key?
    refute sub.to_subscribe_message.key?(:masterKey)
  end

  # ---- run_until_signal! (item 6) -------------------------------------

  def test_run_until_signal_blocks_until_signal_then_shuts_down
    # Use a recorder client to verify shutdown is called from the main
    # thread (not the trap context). Skip the live socket entirely.
    recorder = ShutdownRecorderClient.new

    # Send ourselves SIGUSR1 from a worker thread after the helper has
    # had a chance to install its trap. SIGUSR1 is safe because it's
    # not a default Ruby signal handler.
    signal_thread = Thread.new do
      sleep 0.05  # let trap install
      Process.kill(:USR1, Process.pid)
    end

    enable_live_query do
      Parse::LiveQuery.run_until_signal!(
        client: recorder, signals: [:USR1],
        shutdown_timeout: 0.1, poll_interval: 0.01,
      )
    end

    signal_thread.join(1.0)
    assert recorder.shutdown_called?, "client.shutdown must have been called"
    # The trap context check: ensure shutdown ran on the main thread
    # (the helper's `ensure` block), not in the trap handler itself.
    # If it had run in the trap, ThreadError would have killed the
    # helper before reaching `ensure` and we'd have no shutdown call.
    assert_equal Thread.main.object_id, recorder.shutdown_thread_id
  end

  def test_run_until_signal_yields_client_before_waiting
    recorder = ShutdownRecorderClient.new
    yielded = []
    signal_thread = Thread.new do
      sleep 0.05
      Process.kill(:USR1, Process.pid)
    end

    enable_live_query do
      Parse::LiveQuery.run_until_signal!(
        client: recorder, signals: [:USR1],
        shutdown_timeout: 0.1, poll_interval: 0.01,
      ) do |c|
        yielded << c
      end
    end

    signal_thread.join(1.0)
    assert_equal [recorder], yielded
  end

  def test_run_until_signal_restores_prior_trap_handlers
    original = Signal.trap(:USR2, "DEFAULT")
    recorder = ShutdownRecorderClient.new
    signal_thread = Thread.new do
      sleep 0.05
      Process.kill(:USR2, Process.pid)
    end

    enable_live_query do
      Parse::LiveQuery.run_until_signal!(
        client: recorder, signals: [:USR2],
        shutdown_timeout: 0.1, poll_interval: 0.01,
      )
    end

    signal_thread.join(1.0)
    # After the helper returns, the prior trap should be restored.
    # Set it back to "DEFAULT" via re-trap and compare.
    current = Signal.trap(:USR2, original || "DEFAULT")
    # current is whatever was installed before the second `Signal.trap`
    # — it must NOT be our helper's Proc.
    refute_kind_of Proc, current,
      "helper must have restored the prior trap handler"
  ensure
    Signal.trap(:USR2, original || "DEFAULT")
  end

  def test_run_until_signal_raises_not_enabled_when_toggle_off
    # Wrap in enable_live_query(false) — match the rest of the file's
    # save/restore discipline so a regression in default-value handling
    # doesn't leak into other tests.
    prev = Parse.live_query_enabled?
    begin
      Parse.live_query_enabled = false
      assert_raises(Parse::LiveQuery::NotEnabledError) do
        Parse::LiveQuery.run_until_signal!(
          client: ShutdownRecorderClient.new, signals: [:USR1],
        )
      end
    ensure
      Parse.live_query_enabled = prev
    end
  end

  def test_run_until_signal_rejects_empty_signals_array
    enable_live_query do
      err = assert_raises(ArgumentError) do
        Parse::LiveQuery.run_until_signal!(
          client: ShutdownRecorderClient.new, signals: [],
        )
      end
      assert_match(/non-empty Array/, err.message)
    end
  end

  def test_run_until_signal_rejects_non_array_signals
    enable_live_query do
      assert_raises(ArgumentError) do
        Parse::LiveQuery.run_until_signal!(
          client: ShutdownRecorderClient.new, signals: :USR1,
        )
      end
    end
  end

  private

  # Minimal mock — records whether shutdown was called and from which
  # thread. Lives entirely in test memory.
  class ShutdownRecorderClient
    attr_reader :shutdown_thread_id

    def initialize
      @shutdown_called = false
      @shutdown_thread_id = nil
    end

    def shutdown(timeout: 5.0)
      @shutdown_called = true
      @shutdown_thread_id = Thread.current.object_id
    end

    def shutdown_called?
      @shutdown_called
    end
  end

  def stub_client(master_key:)
    Class.new do
      attr_reader :master_key
      def initialize(master_key)
        @master_key = master_key
      end
    end.new(master_key)
  end

  def build_subscription
    Parse::LiveQuery::Subscription.new(
      client: stub_client(master_key: nil),
      class_name: "Post",
      query: {},
    )
  end

  def enable_live_query
    prev = Parse.live_query_enabled?
    Parse.live_query_enabled = true
    yield
  ensure
    Parse.live_query_enabled = prev
  end
end
