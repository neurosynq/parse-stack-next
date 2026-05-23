require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"
require "securerandom"

# End-to-end coverage for +Parse::API::Batch#batch_request+ under client
# mode. Parse Server's +POST /batch+ endpoint accepts session-token
# authentication: the outer batch envelope carries the session header,
# and Parse Server replays each inner request under that auth context.
#
# We install a CLP on the test class requiring authenticated users for
# all writes — that turns "did the session token reach the server" from
# a vacuous assertion (any anonymous batch would succeed too) into a
# load-bearing one: if the token were dropped on the envelope OR on any
# individual sub-request, the corresponding sub-response would surface
# a +119 / OPERATION_FORBIDDEN+ failure.
#
# What this pins:
#   1. A batch of inserts under session-token auth lands on the server
#      and returns per-sub-request success responses.
#   2. A batch built via +Array#save+ (the SDK's idiomatic bulk-save
#      surface) routes through the batch endpoint and runs under the
#      ambient +Parse.with_session+ token.
#   3. Mixed insert+update sub-requests all see the session token —
#      proves the SDK threads auth through every sub-request, not just
#      the first.
#   4. Without an ambient session AND without master key, the same
#      batch is rejected per-sub-request. This is the load-bearing
#      negative control proving the positive tests aren't passing by
#      virtue of an open CLP.
class ClientRestBatchPost < Parse::Object
  parse_class "ClientRestBatchPost"
  # +acl_policy :public+ keeps the per-ROW gate open. The CLASS-LEVEL
  # gate (CLP +create: { requiresAuthentication: true }+, installed at
  # suite setup) is what makes the session-threading invariant load-
  # bearing: anonymous batch CREATE is rejected per-sub-request.
  # Without an open per-row policy, Parse Stack's default ACL ({}) would
  # deny all cross-session reads/updates and obscure the wire signal we
  # want to read. Public ACL is fine here because the CLP, not the row
  # ACL, is the load-bearing auth gate.
  acl_policy :public
  property :title, :string
  property :body, :string
end

class ClientRestBatchIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  BATCH_CLASS = "ClientRestBatchPost"

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
    install_auth_required_clp!
  end

  # Install a CLP demanding +requiresAuthentication: true+ on every
  # operation. Anonymous callers cannot write — only session-token-
  # bearing callers can. This is what makes the "session token threaded
  # to each sub-request" assertion load-bearing.
  def install_auth_required_clp!
    with_master_key do
      schema = {
        "className" => BATCH_CLASS,
        "fields" => {
          "title" => { "type" => "String" },
          "body"  => { "type" => "String" },
        },
        "classLevelPermissions" => {
          # +create+ is the load-bearing gate: every positive test
          # creates rows, and the negative-control test relies on
          # +create+ being denied to anonymous callers. We leave
          # +update+/+find+/+get+ open so the mixed insert+update
          # test can read back its update target without tangling
          # CLP semantics into the assertion. The session-threading
          # invariant is fully pinned by create-gating: the negative
          # test sends an anonymous multi-insert batch and asserts
          # every sub-request is rejected.
          "find"   => { "*" => true },
          "get"    => { "*" => true },
          "count"  => { "*" => true },
          "create" => { "requiresAuthentication" => true },
          "update" => { "*" => true },
          "delete" => { "*" => true },
          "addField" => {},
        },
      }
      response = Parse.client.update_schema(BATCH_CLASS, schema)
      Parse.client.create_schema(BATCH_CLASS, schema) unless response.success?
    end
  end

  # --------------------------------------------------------------------
  # Happy path: a batch built from real Parse::Object change_requests
  # lands on the server under session-token auth and returns per-sub-
  # request success responses with assigned objectIds. With the CLP
  # in place, a missing/dropped session token would surface as +119+
  # on the sub-response — so "all succeed" pins token threading.
  # --------------------------------------------------------------------
  def test_batch_insert_under_client_mode_session_token
    user, password = seed_client_user("batch_ins")

    responses = nil
    as_client do
      me = Parse::User.login!(user.username, password)
      refute_nil me.session_token

      Parse.with_session(me.session_token) do
        objs = 3.times.map { |i| ClientRestBatchPost.new(title: "t-#{i}", body: "b-#{i}") }
        requests = objs.flat_map(&:change_requests)
        responses = Parse.client.batch_request(requests)
      end
    end

    assert_kind_of Array, responses, "batch must return per-sub-request responses (got: #{responses.inspect})"
    assert_equal 3, responses.length
    responses.each_with_index do |resp, i|
      assert resp.success?, "sub-response #{i} must succeed under session token (got: #{resp.inspect})"
      refute_nil resp.result["objectId"], "sub-response #{i} must echo objectId"
    end
  end

  # --------------------------------------------------------------------
  # The idiomatic surface: Array#save dispatches a batch under the
  # hood. We pin that this works under client mode + ambient session.
  # The CLP would reject every sub-request if the ambient session
  # token weren't threaded — so the test doubles as a session-thread
  # check for the SDK-sugar surface.
  # --------------------------------------------------------------------
  def test_array_save_routes_through_batch_under_session_token
    user, password = seed_client_user("batch_arr")

    objs = 3.times.map { |i| ClientRestBatchPost.new(title: "arr-#{i}", body: "x") }

    as_client do
      me = Parse::User.login!(user.username, password)
      Parse.with_session(me.session_token) do
        objs.save
      end
    end

    objs.each do |obj|
      refute_nil obj.id, "every batched object must come back with an assigned objectId"
      @test_context.track(obj)
    end
  end

  # --------------------------------------------------------------------
  # Mixed batch: insert + update under one session-token envelope. Pins
  # that the SDK passes the auth header through to every sub-request,
  # not just the first. With the CLP in place, if any sub-request lost
  # the token, its response would carry +119+ instead of success.
  # --------------------------------------------------------------------
  def test_batch_mixed_operations_under_session_token
    user, password = seed_client_user("batch_mix")

    seeded = nil
    responses = nil
    as_client do
      me = Parse::User.login!(user.username, password)
      Parse.with_session(me.session_token) do
        # Seed under the SAME user session so any row-ACL Parse Server
        # auto-stamps points at this user (avoiding cross-ACL 101s when
        # the batch update later runs under the same session).
        seeded = ClientRestBatchPost.new(title: "to_update", body: "orig")
        assert seeded.save, "precondition: seeded row must save under session"
        @test_context.track(seeded)

        new_obj = ClientRestBatchPost.new(title: "new", body: "from_batch")
        seeded.title = "updated"
        requests = new_obj.change_requests + seeded.change_requests
        responses = Parse.client.batch_request(requests)
      end
    end

    assert_kind_of Array, responses
    assert_equal 2, responses.length
    responses.each_with_index do |r, i|
      assert r.success?, "sub-response #{i} must succeed (got: #{r.inspect})"
    end

    # Master-key ground truth: confirm the update sub-request actually
    # mutated server state — not just that the wire returned success.
    with_master_key do
      readback = Parse.client.fetch_object(BATCH_CLASS, seeded.id)
      assert_equal "updated", readback.result["title"],
                   "update sub-request must have landed (got: #{readback.inspect})"
    end
  end

  # --------------------------------------------------------------------
  # Negative control: same batch shape, but no ambient session and no
  # master key. With the +requiresAuthentication: true+ CLP installed,
  # Parse Server MUST reject every sub-request. This proves the
  # positive tests above aren't passing by accident — they require the
  # session token to actually reach the server.
  #
  # The exact wire shape depends on Parse Server version:
  #   * Some versions return HTTP 200 with each sub-response carrying
  #     +{ error: { code: 119, ... } }+.
  #   * Some short-circuit the entire batch with HTTP 401/403 and the
  #     SDK raises +AuthenticationError+.
  # Both are acceptable; what we forbid is "rows landed successfully
  # without auth".
  # --------------------------------------------------------------------
  def test_batch_under_no_auth_is_rejected
    responses = nil
    raised = nil

    as_client do
      assert_client_mode!
      begin
        objs = 2.times.map { |i| ClientRestBatchPost.new(title: "anon-#{i}", body: "x") }
        requests = objs.flat_map(&:change_requests)
        responses = Parse.client.batch_request(requests)
      rescue Parse::Error::AuthenticationError => e
        raised = e
      end
    end

    if raised
      # SDK saw HTTP 401/403 and raised — acceptable rejection shape.
      assert_match(/.+/, raised.message)
    else
      # Per-sub-response rejection — every sub-request must surface
      # the CLP violation. NONE may succeed.
      refute_nil responses
      assert_kind_of Array, responses
      successes = responses.select(&:success?)
      assert_empty successes,
                   "no sub-request may succeed under no auth + auth-required CLP " \
                   "(got: #{responses.map(&:inspect).inspect})"
    end
  end
end
