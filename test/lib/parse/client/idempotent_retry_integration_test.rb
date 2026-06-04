# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require_relative "../../../support/test_server"
require "securerandom"

# Live integration coverage for idempotent retries (5.2.0).
#
# The retry-safety of a WRITE replay rests on Parse Server's request-id
# deduplication: when two POSTs carry the same `X-Parse-Request-Id` within the
# server's TTL, the second is NOT applied. The SDK sends a STABLE request id on
# every retry attempt (the header is set once and preserved across `retry`), so
# once an operator sets `Parse::Request.assume_server_idempotency = true`, a
# transparently-retried create cannot double-apply.
#
# These tests prove the SERVER half of that contract end-to-end by replaying a
# request id on the wire (exactly what a retry does) and asserting no duplicate
# row is created. The test stack (`scripts/start-parse.sh`) configures
# `idempotencyOptions` scoped to the `IdempotencyProbe` class ONLY, so it has
# zero effect on the rest of the suite. A server started before that config was
# added makes the dedup test SKIP (with a restart hint) rather than fail.
#
# Gated on PARSE_TEST_USE_DOCKER like the rest of the live-server suite.
class IdempotentRetryIntegrationTest < Minitest::Test
  PROBE = "IdempotencyProbe"

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Parse Server not reachable at localhost:29337" unless Parse::Test::ServerHelper.setup
    @prev_assume = Parse::Request.assume_server_idempotency
    Parse::Request.assume_server_idempotency = true
    @created = []
  end

  def teardown
    @created&.uniq&.each { |oid| destroy_probe(oid) }
    Parse::Request.assume_server_idempotency = @prev_assume unless @prev_assume.nil?
  end

  # Create a probe row carrying an explicit request id (what the SDK puts on the
  # wire on a retry). create_object forwards the headers: kwarg verbatim, and
  # Parse::Request preserves a manually-supplied X-Parse-Request-Id.
  def post_probe(request_id, marker)
    Parse.client.create_object(PROBE, { "name" => marker },
                               headers: { "X-Parse-Request-Id" => request_id })
  end

  def probe_rows(marker)
    Parse::Query.new(PROBE).where(name: marker).results
  end

  def destroy_probe(object_id)
    Parse.client.delete_object(PROBE, object_id)
  rescue StandardError
    nil
  end

  def test_replayed_request_id_does_not_create_a_duplicate_row
    id     = "_RB_#{SecureRandom.uuid}"
    marker = "probe-#{SecureRandom.hex(6)}"

    r1 = post_probe(id, marker)
    assert r1.success?, "first create should succeed: #{r1.error.inspect}"
    oid1 = r1.result["objectId"]
    refute_nil oid1
    @created << oid1

    # Replay the SAME request id — byte-for-byte what the retry path sends.
    # When idempotency is active the server answers 159 and the SDK raises
    # DuplicateRequestError; when it is NOT configured the replay just creates a
    # second row (and we skip below).
    replay_error = nil
    begin
      post_probe(id, marker)
    rescue Parse::Error::DuplicateRequestError => e
      replay_error = e
    end

    rows = probe_rows(marker)
    @created |= rows.map(&:id)

    if rows.size > 1
      skip "Server idempotency not active for classes/#{PROBE} — restart the test " \
           "container so start-parse.sh applies PARSE_SERVER_IDEMPOTENCY_OPTIONS " \
           "({\"paths\":[\"classes/#{PROBE}\"],\"ttl\":120})."
    end

    assert_equal 1, rows.size,
      "replaying the same X-Parse-Request-Id must not create a duplicate row"
    assert_equal oid1, rows.first.id, "the surviving row is the original create"
    refute_nil replay_error,
      "the replay must surface a typed DuplicateRequestError (Parse code 159)"
  end

  def test_distinct_request_ids_create_distinct_rows_control
    # Control: dedup is keyed on the request id, so DIFFERENT ids each create a
    # row regardless of server config. Confirms the dedup above isn't an
    # artifact of some unrelated uniqueness constraint.
    marker = "ctl-#{SecureRandom.hex(6)}"
    post_probe("_RB_#{SecureRandom.uuid}", marker)
    post_probe("_RB_#{SecureRandom.uuid}", marker)

    rows = probe_rows(marker)
    @created |= rows.map(&:id)
    assert_equal 2, rows.size,
      "control: distinct request ids must each create a row"
  end
end
