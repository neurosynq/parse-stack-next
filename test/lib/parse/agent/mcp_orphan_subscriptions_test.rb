# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require_relative "../../../../lib/parse/agent/mcp_dispatcher"
require_relative "../../../../lib/parse/agent/mcp_subscriptions"

# Orphaned-session reaping for Parse::Agent::MCPSubscriptions::Manager.
#
# A session is orphaned while it holds subscriptions with no listening stream
# attached: it subscribed but never opened the GET stream, or subscribed again
# after its stream closed. Normal teardown (unsubscribe, stream close, DELETE)
# already releases subscriptions; these tests cover the case where none of
# those ever happens.
class MCPOrphanSubscriptionsTest < Minitest::Test
  M = Parse::Agent::MCPSubscriptions

  class Sub
    def initialize = @unsubscribed = false
    def on(*) = self
    def unsubscribe = @unsubscribed = true
    def unsubscribed? = @unsubscribed
  end

  class LQ
    attr_reader :subs

    def initialize = @subs = []

    def subscribe(*_args, **_creds)
      s = Sub.new
      @subs << s
      s
    end
  end

  # Master-key agent double: passes the class-authorization gate and derives
  # master credentials.
  class Agent
    attr_accessor :correlation_id
    attr_reader :session_token, :acl_user_scope, :acl_role_scope, :acl_scope, :client

    def initialize
      @client = Struct.new(:master_key).new("mk")
    end

    def permissions = :readonly
    def client_mode? = false
  end

  def setup
    @now = 1_000.0
    @lq = LQ.new
  end

  def manager(ttl: 60)
    M::Manager.new(supported: true, live_query_client: @lq, debounce_interval: 0,
                   orphan_ttl: ttl, clock: -> { @now })
  end

  def subscribe(mgr, sid, uri = "parse://Post/count")
    Parse::Agent::Tools.stub(:assert_class_accessible!, true) do
      mgr.subscribe(session_id: sid, uri: uri, agent: Agent.new)
    end
  end

  def test_session_without_listener_is_reaped_after_ttl
    mgr = manager(ttl: 60)
    subscribe(mgr, "orphan")
    assert_equal 1, mgr.orphaned_session_count

    @now += 59
    assert_equal 0, mgr.reap_orphans!, "still inside the grace period"
    refute @lq.subs.first.unsubscribed?

    @now += 1
    assert_equal 1, mgr.reap_orphans!
    assert @lq.subs.first.unsubscribed?
    assert_equal 0, mgr.subscription_count
    assert_equal 0, mgr.orphaned_session_count
  end

  def test_attached_session_is_never_reaped
    mgr = manager(ttl: 60)
    mgr.attach_listener("live") { }
    subscribe(mgr, "live")
    @now += 10_000
    assert_equal 0, mgr.reap_orphans!
    refute @lq.subs.first.unsubscribed?
  end

  def test_attaching_inside_the_grace_period_clears_the_orphan_mark
    mgr = manager(ttl: 60)
    subscribe(mgr, "late")
    @now += 30
    mgr.attach_listener("late") { }
    assert_equal 0, mgr.orphaned_session_count
    @now += 10_000
    assert_equal 0, mgr.reap_orphans!
    refute @lq.subs.first.unsubscribed?
  end

  def test_subscribing_after_the_stream_closed_starts_a_new_grace_period
    mgr = manager(ttl: 60)
    mgr.attach_listener("s") { }
    subscribe(mgr, "s")
    mgr.detach_listener("s") # stream closed; its subscription is torn down
    assert @lq.subs.first.unsubscribed?

    subscribe(mgr, "s", "parse://Post/samples") # arrives after the stream closed
    assert_equal 1, mgr.orphaned_session_count
    @now += 60
    assert_equal 1, mgr.reap_orphans!
    assert @lq.subs.last.unsubscribed?
  end

  def test_reaping_runs_opportunistically_on_subscribe_and_attach
    mgr = manager(ttl: 60)
    subscribe(mgr, "a")
    @now += 61
    subscribe(mgr, "b") # triggers a reap of "a"
    assert @lq.subs.first.unsubscribed?
    refute @lq.subs.last.unsubscribed?

    @now += 61
    mgr.attach_listener("c") { } # triggers a reap of "b"
    assert @lq.subs.last.unsubscribed?
  end

  def test_unsubscribing_everything_clears_the_orphan_mark
    mgr = manager(ttl: 60)
    subscribe(mgr, "s")
    mgr.unsubscribe(session_id: "s", uri: "parse://Post/count")
    assert_equal 0, mgr.orphaned_session_count
  end

  def test_nil_ttl_disables_reaping
    mgr = manager(ttl: nil)
    subscribe(mgr, "s")
    @now += 1_000_000
    assert_equal 0, mgr.reap_orphans!
    refute @lq.subs.first.unsubscribed?
  end

  def test_invalid_ttl_rejected
    assert_raises(ArgumentError) { manager(ttl: 0) }
    assert_raises(ArgumentError) { manager(ttl: "60") }
  end

  # Race coverage: attach and reap contend for the same session from many
  # threads. Each session must end up either attached with its subscription
  # alive, or reaped with its subscription torn down; never attached with its
  # subscription silently removed while the attach believed it kept it, and
  # never a subscription left running for a reaped session.
  def test_concurrent_attach_and_reap_leave_consistent_state
    mgr = manager(ttl: 1)
    sids = (1..50).map { |i| "race-#{i}" }
    sids.each { |sid| subscribe(mgr, sid) }
    @now += 2 # every session is past its grace period

    threads = sids.map { |sid| Thread.new { mgr.attach_listener(sid) { } } }
    threads += Array.new(4) { Thread.new { mgr.reap_orphans! } }
    threads.each(&:join)

    sids.each_with_index do |sid, i|
      sub = @lq.subs[i]
      if sub.unsubscribed?
        # Reaped before the attach: the session holds no subscriptions now.
        refute_includes mgr.instance_variable_get(:@sessions).keys, sid
      else
        # Attached before the reap: kept, and no longer orphaned.
        assert mgr.instance_variable_get(:@sessions).key?(sid)
      end
    end
    assert_equal 0, mgr.orphaned_session_count
  end
end
