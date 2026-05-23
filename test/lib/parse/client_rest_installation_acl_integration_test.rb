require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"
require "securerandom"

# End-to-end coverage for +_Installation+ row access under client
# mode. Parse Server's +_Installation+ collection is the canonical
# place where a mobile/web client SDK registers itself to receive
# pushes — so the row-create surface MUST work without a master key.
# But the read/update surface is sensitive: an unauthenticated client
# enumerating installations would expose the user's device fleet
# (deviceToken, installationId, channels subscribed).
#
# What this pins:
#   1. A client-mode caller CAN create an Installation row (the typical
#      "register on app start" flow).
#   2. An anonymous (no session, no master) +find+ across the
#      collection does NOT silently return everyone's installations —
#      the SDK does not bypass auth, and the server response must
#      either reject the call or return only rows readable to the
#      caller (which, with no auth, is none).
#   3. An installation row whose ACL restricts read+write to a single
#      user cannot be fetched cross-user under session-token auth.
class ClientRestInstallationAclIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
  end

  # --------------------------------------------------------------------
  # Happy path: client-mode caller registers an Installation. This is
  # the typical mobile-SDK boot flow and must succeed without master
  # key. We use the API path directly because Parse::Installation has
  # SDK-side conveniences that may differ across versions.
  # --------------------------------------------------------------------
  def test_client_can_create_installation_row
    iid = SecureRandom.uuid

    response = nil
    as_client do
      assert_client_mode!
      response = Parse.client.create_object(
        "_Installation",
        {
          "installationId" => iid,
          "deviceType" => "ios",
          "deviceToken" => SecureRandom.hex(32),
          "channels" => ["news"],
        },
      )
    end

    assert response.success?,
           "client-mode Installation create must succeed (got: #{response.inspect})"
    obj_id = response.result["objectId"]
    refute_nil obj_id, "server must assign objectId"

    # Server-side: row actually landed and carries the installationId
    # we sent.
    with_master_key do
      readback = Parse.client.fetch_object("_Installation", obj_id)
      assert_equal iid, readback.result["installationId"]
    end
  end

  # --------------------------------------------------------------------
  # ACL boundary: an installation row whose ACL restricts read to a
  # specific user must NOT be readable by other client-mode callers.
  # The exact rejection shape depends on the Parse Server _Installation
  # CLP (varies by version) — the invariant is "the row's contents do
  # not leak to the wrong user".
  # --------------------------------------------------------------------
  def test_owner_scoped_installation_not_readable_by_other_user
    owner,    owner_pwd    = seed_client_user("inst_owner")
    intruder, intruder_pwd = seed_client_user("inst_intruder")

    obj_id = nil
    with_master_key do
      acl = Parse::ACL.new
      acl.apply(owner.id, true, true) # owner-only
      response = Parse.client.create_object(
        "_Installation",
        {
          "installationId" => SecureRandom.uuid,
          "deviceType" => "ios",
          "deviceToken" => SecureRandom.hex(32),
          "ACL" => acl.as_json,
        },
      )
      assert response.success?, response.inspect
      obj_id = response.result["objectId"]
    end

    as_client do
      # Owner can read.
      owner_session = Parse::User.login!(owner.username, owner_pwd).session_token
      owner_get = Parse.client.fetch_object("_Installation", obj_id, session_token: owner_session)
      assert owner_get.success?, "owner must read their own installation row (got: #{owner_get.inspect})"

      # Intruder cannot.
      intruder_session = Parse::User.login!(intruder.username, intruder_pwd).session_token
      intruder_get = Parse.client.fetch_object("_Installation", obj_id, session_token: intruder_session)
      refute intruder_get.success?,
             "non-owner must NOT read an owner-scoped Installation row (got: #{intruder_get.inspect})"
    end
  end

  # --------------------------------------------------------------------
  # Anonymous (no session, no master) +find+ must not enumerate
  # everyone's installations. Either the server rejects the call or
  # the result set is filtered to nothing. Pin "no silent enumeration".
  # --------------------------------------------------------------------
  def test_anonymous_find_does_not_enumerate_installations
    # Seed two installations belonging to nobody so they're definitely
    # present in the collection — proves the "filtered to nothing"
    # branch is meaningful.
    seeded_ids = []
    with_master_key do
      2.times do
        response = Parse.client.create_object(
          "_Installation",
          {
            "installationId" => SecureRandom.uuid,
            "deviceType" => "ios",
            "deviceToken" => SecureRandom.hex(32),
          },
        )
        assert response.success?
        seeded_ids << response.result["objectId"]
      end
    end

    # Positive control: under master key, the SDK CAN see the seeded
    # rows. Without this, "anonymous finds zero rows" could be a
    # vacuous pass (e.g., the collection got nuked between seed and
    # find). Pinning the master-key readback first proves the rows
    # really live in the collection.
    master_ids = nil
    with_master_key do
      master_resp = Parse.client.find_objects("_Installation", {})
      assert master_resp.success?, "master-key find must succeed (got: #{master_resp.inspect})"
      master_ids = master_resp.results.map { |r| r["objectId"] }
      seeded_ids.each do |sid|
        assert_includes master_ids, sid,
                        "master-key control: seeded id #{sid} must be visible to master"
      end
    end

    as_client do
      assert_client_mode!
      response = Parse.client.find_objects("_Installation", {})
      # Either the call fails OR returns a result set that does NOT
      # contain the seeded rows. The invariant is the negation: an
      # unauthenticated caller must NEVER see rows that the master key
      # just confirmed exist.
      if response.success?
        anon_ids = response.results.map { |r| r["objectId"] }
        leaked_seeded = seeded_ids & anon_ids
        assert_empty leaked_seeded,
                     "anonymous find on _Installation leaked seeded rows: " \
                     "#{leaked_seeded.inspect} (seeded=#{seeded_ids.inspect}, anon=#{anon_ids.inspect})"
      else
        # Server rejected outright — also satisfies "no enumeration".
        refute_nil response.code,
                   "rejection must carry a Parse error code (got: #{response.inspect})"
      end
    end
  end
end
