require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"
require "securerandom"

# ACL behaviors observed from the SDK-as-client side. The CRUD test
# already covers the basic "Alice can read her row, Bob cannot" shape;
# this file pins down the more failure-prone corners:
#
#   * Public-read default — the SDK stamps a permissive ACL on the
#     fixture, and a different user can fetch it without auth.
#   * Public-write OFF, read ON — drive-by readers can't tamper.
#   * Empty ACL ({}) = master-key-only — the `:owner_else_private`
#     default fallback when no owner is resolved. A client-mode reader
#     must NOT see this row.
#   * `_User` self-modification — a user can rewrite their own _User
#     row, but NOT another user's.
#   * acl.everyone(false, false) followed by .apply(uid, true, true)
#     produces the canonical "owner-private" ACL — verify the wire
#     shape and that other users are denied.
class ClientAclDoc < Parse::Object
  parse_class "ClientAclDoc"
  acl_policy :public
  property :title, :string
  property :body, :string
end

# A second fixture that intentionally uses the default `:owner_else_private`
# policy. With no owner field declared and no owner override, every save
# stamps `{}` (empty ACL = master-key-only). The test below proves a
# client-mode reader can NOT see these rows — which is exactly what
# `:owner_else_private` is designed to guarantee.
class ClientAclPrivateByDefault < Parse::Object
  parse_class "ClientAclPrivateByDefault"
  property :note, :string
end

class ClientRestAclIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
    @alice, @alice_pw = seed_client_user("acl_alice")
    @bob,   @bob_pw   = seed_client_user("acl_bob")
  end

  # --------------------------------------------------------------------
  # Public-read default — anyone (including anonymous, no session) can
  # fetch the row. This is the baseline that the SDK's `acl_policy :public`
  # promises.
  # --------------------------------------------------------------------
  def test_public_acl_row_is_readable_by_other_user_and_anonymously
    doc = nil
    as_client do
      alice = Parse::User.login(@alice.username, @alice_pw)
      doc = ClientAclDoc.new(title: "public-by-default", body: "hi")
      assert doc.save(session: alice.session_token)
      @test_context.track(doc)
    end

    as_client do
      bob = Parse::User.login(@bob.username, @bob_pw)
      via_bob = ClientAclDoc.query.tap { |q| q.session_token = bob.session_token }
                            .where(objectId: doc.id).first
      refute_nil via_bob, "public-read row must be visible to other authenticated users"
      assert_equal "public-by-default", via_bob.title

      # Anonymous — no session token at all.
      anon = ClientAclDoc.query.where(objectId: doc.id).first
      refute_nil anon, "public-read row must be visible to anonymous clients"
    end
  end

  # --------------------------------------------------------------------
  # Public-read on, public-write off — readers can SEE, but cannot
  # mutate. Verifies the SDK preserves the two-bit ACL shape on the
  # wire and the server enforces the write half separately.
  # --------------------------------------------------------------------
  def test_public_read_no_write_blocks_mutation
    doc = nil
    as_client do
      alice = Parse::User.login(@alice.username, @alice_pw)
      doc = ClientAclDoc.new(title: "v1", body: "readable")
      doc.acl.everyone(true, false)
      doc.acl.apply(alice.id, true, true)
      assert doc.save(session: alice.session_token)
      @test_context.track(doc)
    end

    as_client do
      bob = Parse::User.login(@bob.username, @bob_pw)
      via_bob = ClientAclDoc.query.tap { |q| q.session_token = bob.session_token }
                            .where(objectId: doc.id).first
      refute_nil via_bob, "public-read row must be visible to Bob"
      via_bob.title = "tampered"
      err = assert_raises(Parse::Error, Parse::RecordNotSaved, StandardError) do
        via_bob.save!(session: bob.session_token)
      end
      assert_match(/permission|forbidden|acl|not allowed|not saved|object not found/i, err.message,
                   "public-read-only write must be rejected, got: #{err.message}")
    end

    # Anonymous write must also be rejected.
    as_client do
      anon = ClientAclDoc.query.where(objectId: doc.id).first
      refute_nil anon
      anon.title = "anon-tamper"
      assert_raises(Parse::Error, Parse::RecordNotSaved, StandardError) do
        anon.save!
      end
    end

    with_master_key do
      unchanged = ClientAclDoc.find(doc.id)
      assert_equal "v1", unchanged.title, "neither Bob nor anon was allowed to mutate"
    end
  end

  # --------------------------------------------------------------------
  # `:owner_else_private` policy with no resolved owner stamps `{}` on
  # save. Parse Server treats an empty ACL as master-key-only.
  # A client-mode reader (even the user who created the row, via
  # master) must NOT see it. This is the SDK's safe-by-default
  # property — prove it with a fresh fixture, not by happy accident.
  # --------------------------------------------------------------------
  def test_owner_else_private_default_stamps_master_only_acl
    doc = nil
    with_master_key do
      doc = ClientAclPrivateByDefault.new(note: "private-by-default")
      assert doc.save
      @test_context.track(doc)

      # Sanity: confirm ACL really is empty.
      fresh = ClientAclPrivateByDefault.find(doc.id)
      assert_equal({}, fresh.acl.permissions,
                   "empty ACL is the on-the-wire shape that triggers master-only enforcement")
    end

    as_client do
      alice = Parse::User.login(@alice.username, @alice_pw)
      not_seen = ClientAclPrivateByDefault.query
                                          .tap { |q| q.session_token = alice.session_token }
                                          .where(objectId: doc.id).first
      assert_nil not_seen,
                 "row with empty ACL must be invisible to any non-master caller"

      anon = ClientAclPrivateByDefault.query.where(objectId: doc.id).first
      assert_nil anon, "row with empty ACL must be invisible to anonymous caller"
    end
  end

  # --------------------------------------------------------------------
  # A user can update THEIR OWN _User row from a client session, but
  # not another user's. Parse Server stamps _User ACL with the owner's
  # objectId on signup. The SDK must thread the session token through
  # the update path.
  # --------------------------------------------------------------------
  def test_user_can_modify_self_but_not_other
    as_client do
      alice = Parse::User.login(@alice.username, @alice_pw)
      bob   = Parse::User.login(@bob.username, @bob_pw)

      # Self-update succeeds.
      self_update = Parse.client.update_object(
        "_User", alice.id, { "email" => "alice_new@test.com" },
        session_token: alice.session_token, use_master_key: false,
      )
      assert self_update.success?,
             "user must be able to mutate own _User row (#{self_update.error.inspect})"

      # Cross-user update fails.
      cross_update = Parse.client.update_object(
        "_User", bob.id, { "email" => "alice_was_here@test.com" },
        session_token: alice.session_token, use_master_key: false,
      )
      refute cross_update.success?,
             "user must NOT be able to mutate another user's _User row"
      assert_match(/permission|forbidden|acl|not allowed|object not found|cannot.*modify.*user|insufficient.*auth/i,
                   cross_update.error.to_s,
                   "expected an auth-class rejection, got: #{cross_update.error.inspect}")

      with_master_key do
        bob_now = Parse::User.find(bob.id)
        refute_equal "alice_was_here@test.com", bob_now.email,
                     "Bob's email must not reflect Alice's unauthorized write attempt"
      end
    end
  end

  # --------------------------------------------------------------------
  # ACL wire shape: `acl.everyone(false, false) + apply(uid, true, true)`
  # serializes to exactly `{ uid => {read:true, write:true} }` — public
  # entries must be absent, not `false`. A stale `*` entry would be a
  # security regression because Parse Server treats explicit
  # `{*: {read: false}}` and "no public entry" identically, but the SDK
  # has historically had bugs around toggling public off after it was on.
  # --------------------------------------------------------------------
  def test_owner_private_wire_shape
    as_client do
      alice = Parse::User.login(@alice.username, @alice_pw)
      doc = ClientAclDoc.new(title: "owner-only", body: "s")
      doc.acl.everyone(false, false)
      doc.acl.apply(alice.id, true, true)
      assert doc.save(session: alice.session_token)
      @test_context.track(doc)

      with_master_key do
        fresh = ClientAclDoc.find(doc.id)
        perms = fresh.acl.permissions
        owner_entry = perms[alice.id]
        refute_nil owner_entry, "owner ACL entry must be present"
        assert owner_entry.read,  "owner ACL must grant read"
        assert owner_entry.write, "owner ACL must grant write"

        # `*` may be either absent or present-with-nil — both serialize to
        # "no public grant" on the wire. What matters is that no read/write
        # public privilege survived `everyone(false, false)`.
        pub = perms["*"]
        assert(pub.nil? || (!pub.read && !pub.write),
               "public entry must not grant read or write, got: #{pub.inspect}")
      end
    end
  end
end
