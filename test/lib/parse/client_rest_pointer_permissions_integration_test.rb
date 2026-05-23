require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"
require "securerandom"

# End-to-end coverage for CLP +readUserFields+ / +writeUserFields+
# (a.k.a. "pointer permissions") under client mode. These are Parse
# Server's row-level authorization shortcut: instead of stamping per-
# row ACL on every save, the CLP declares "the user pointed at by
# field X may read this row; the user pointed at by field Y may write
# it" — Parse Server then computes effective auth per row at request
# time.
#
# What this pins:
#   1. The user pointed-to by +readUserFields+ CAN find/get rows where
#      that field equals their own pointer; OTHER users CANNOT.
#   2. The user pointed-to by +writeUserFields+ CAN update those rows;
#      OTHER users CANNOT.
#   3. Pointer permissions are enforced on the server, not the SDK —
#      changing the field value (re-pointing at someone else) must
#      itself be blocked, else this becomes a takeover vector.
#
# Schema is installed via +update_schema+/+create_schema+ so the test
# is self-contained.
class ClientRestPointerPermissionsIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  CLASS_NAME = "PointerPermProbe"

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
    @alice, @alice_pwd = seed_client_user("ppp_alice")
    @bob,   @bob_pwd   = seed_client_user("ppp_bob")
    install_class_with_pointer_clp!
  end

  # --------------------------------------------------------------------
  # Install class with readUserFields = [owner], writeUserFields = [owner].
  # The +owner+ column is a pointer-to-User. Rows where +owner+ points
  # at user X are readable AND writable only by X (and master).
  # --------------------------------------------------------------------
  def install_class_with_pointer_clp!
    with_master_key do
      schema = {
        "className" => CLASS_NAME,
        "fields" => {
          "title" => { "type" => "String" },
          "owner" => { "type" => "Pointer", "targetClass" => "_User" },
        },
        "classLevelPermissions" => {
          # Authenticated users can attempt all operations; per-row
          # filtering happens via readUserFields / writeUserFields.
          "find"   => { "requiresAuthentication" => true },
          "get"    => { "requiresAuthentication" => true },
          "count"  => { "requiresAuthentication" => true },
          "create" => { "requiresAuthentication" => true },
          "update" => { "requiresAuthentication" => true },
          "delete" => { "requiresAuthentication" => true },
          "addField" => {},
          "readUserFields"  => ["owner"],
          "writeUserFields" => ["owner"],
        },
      }
      response = Parse.client.update_schema(CLASS_NAME, schema)
      Parse.client.create_schema(CLASS_NAME, schema) unless response.success?
    end
  end

  # --------------------------------------------------------------------
  # Alice creates a row owned by Alice. She can read it back; Bob
  # cannot.
  # --------------------------------------------------------------------
  def test_owner_can_read_other_user_cannot
    alice_row_id = nil

    as_client do
      alice_session = Parse::User.login!(@alice.username, @alice_pwd).session_token
      response = Parse.client.create_object(
        CLASS_NAME,
        { "title" => "alice-owned", "owner" => @alice.pointer.as_json },
        session_token: alice_session,
      )
      assert response.success?, response.inspect
      alice_row_id = response.result["objectId"]
      refute_nil alice_row_id

      # Alice's own read: succeeds.
      readback = Parse.client.fetch_object(CLASS_NAME, alice_row_id, session_token: alice_session)
      assert readback.success?, "owner must read their own row (got: #{readback.inspect})"
      assert_equal "alice-owned", readback.result["title"]

      # Bob's read: must fail (or return nothing).
      bob_session = Parse::User.login!(@bob.username, @bob_pwd).session_token
      bob_get = Parse.client.fetch_object(CLASS_NAME, alice_row_id, session_token: bob_session)
      refute bob_get.success?,
             "non-owner must NOT read Alice's row (got: #{bob_get.inspect})"

      # Bob's find: should return zero rows.
      bob_find = Parse.client.find_objects(
        CLASS_NAME, { where: { owner: @alice.pointer.as_json }.to_json },
        session_token: bob_session,
      )
      assert bob_find.success?, "find must not error, just return empty under pointer-perm"
      assert_equal 0, bob_find.results.length,
                   "pointer-perm find must return no rows for non-owner (got: #{bob_find.results.inspect})"
    end
  end

  # --------------------------------------------------------------------
  # Bob tries to update a row owned by Alice. Must be rejected.
  # --------------------------------------------------------------------
  def test_non_owner_cannot_update
    alice_row_id = nil

    with_master_key do
      response = Parse.client.create_object(
        CLASS_NAME,
        { "title" => "alice-owned-2", "owner" => @alice.pointer.as_json },
      )
      assert response.success?
      alice_row_id = response.result["objectId"]
    end

    as_client do
      bob_session = Parse::User.login!(@bob.username, @bob_pwd).session_token
      response = Parse.client.update_object(
        CLASS_NAME, alice_row_id, { "title" => "hijacked" },
        session_token: bob_session,
      )
      refute response.success?,
             "non-owner update must NOT silently succeed (got: #{response.inspect})"
    end

    # Server-side ground truth: title is unchanged.
    with_master_key do
      readback = Parse.client.fetch_object(CLASS_NAME, alice_row_id)
      assert_equal "alice-owned-2", readback.result["title"]
    end
  end

  # --------------------------------------------------------------------
  # Re-pointing the owner field is itself an update — must be subject
  # to writeUserFields enforcement. Otherwise a non-owner could re-
  # write +owner+ to themselves and walk in. Pin the close.
  # --------------------------------------------------------------------
  def test_non_owner_cannot_re_point_owner_field
    alice_row_id = nil

    with_master_key do
      response = Parse.client.create_object(
        CLASS_NAME,
        { "title" => "owner-takeover", "owner" => @alice.pointer.as_json },
      )
      assert response.success?
      alice_row_id = response.result["objectId"]
    end

    as_client do
      bob_session = Parse::User.login!(@bob.username, @bob_pwd).session_token
      response = Parse.client.update_object(
        CLASS_NAME, alice_row_id, { "owner" => @bob.pointer.as_json },
        session_token: bob_session,
      )
      refute response.success?,
             "non-owner re-point of pointer-perm field must NOT succeed (got: #{response.inspect})"
    end

    with_master_key do
      readback = Parse.client.fetch_object(CLASS_NAME, alice_row_id)
      assert_equal @alice.id, readback.result.dig("owner", "objectId"),
                   "owner field must remain Alice — re-pointing it from non-owner must be rejected"
    end
  end
end
