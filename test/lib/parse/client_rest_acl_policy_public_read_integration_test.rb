require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"
require "securerandom"

# End-to-end coverage for the v5.0 ACL policy additions:
#   acl_policy :public_read
#   acl_policy :owner_but_public_read, owner: <field>
#
# Both policies stamp a public-read grant at save time; the second
# additionally grants R/W to the resolved owner. The save-time resolver
# and the wire-shape branches for both policies live in
# {Parse::Object#_resolve_default_acl} (see the +case policy+ on
# +:public_read+ vs. +:owner_but_public_read+ within that method).
#
# What this file pins down end-to-end against the Docker Parse Server:
#
#   * +:public_read+ — anonymous GET succeeds, anonymous and authenticated
#     non-master PUT both fail (no ACL grant for write to anyone).
#   * +:owner_but_public_read+ with a resolved owner — anonymous GET
#     succeeds, owner PUT succeeds, non-owner PUT and anonymous PUT both
#     fail (only the owner has write).
#   * +:owner_but_public_read+ with NO resolvable owner — falls back to
#     +:public_read+ semantics (public read, no writer).
#   * Wire-shape verification under a master-key fetch: the on-disk ACL
#     for +:public_read+ is exactly +{"*" => {"read" => true}}+, and the
#     fallback shape for +:owner_but_public_read+-without-owner matches.
class PublicReadCatalog < Parse::Object
  parse_class "PublicReadCatalog"
  acl_policy :public_read
  property :title, :string
  property :body, :string
end

class OwnerPublicReadPost < Parse::Object
  parse_class "OwnerPublicReadPost"
  acl_policy :owner_but_public_read, owner: :author
  property :title, :string
  property :body, :string
  belongs_to :author, as: :user
end

class ClientRestAclPolicyPublicReadIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
    @alice, @alice_pw = seed_client_user("pr_alice")
    @bob,   @bob_pw   = seed_client_user("pr_bob")
  end

  # --------------------------------------------------------------------
  # :public_read — the simple catalog-table case. The init-time stamp is
  # public-read, the resolver re-confirms it, and the row lands on the
  # server with +{"*" => {"read" => true}}+ as the on-disk ACL. Any
  # caller can GET it; nobody can PUT it without the master key.
  # --------------------------------------------------------------------
  def test_public_read_row_is_globally_readable_and_globally_unwritable
    doc = nil
    with_master_key do
      doc = PublicReadCatalog.new(title: "lookup", body: "static")
      assert doc.save, "master-key create of a :public_read row must succeed"
      @test_context.track(doc)

      fresh = PublicReadCatalog.find(doc.id)
      perms = fresh.acl.permissions
      pub = perms["*"]
      refute_nil pub, ":public_read must stamp a public ACL entry"
      assert pub.read,  ":public_read must grant public read"
      refute pub.write, ":public_read must NOT grant public write"
      assert_equal 1, perms.size,
                   ":public_read must stamp exactly one ACL entry (the public one), got: #{perms.inspect}"
    end

    # GET succeeds for both an authenticated non-owner and an anonymous
    # caller — the public-read bit is doing the work either way.
    as_client do
      bob = Parse::User.login(@bob.username, @bob_pw)
      via_bob = PublicReadCatalog.query
                                 .tap { |q| q.session_token = bob.session_token }
                                 .where(objectId: doc.id).first
      refute_nil via_bob, ":public_read row must be readable by a session-token caller"
      assert_equal "lookup", via_bob.title

      anon = PublicReadCatalog.query.where(objectId: doc.id).first
      refute_nil anon, ":public_read row must be readable anonymously"
    end

    # PUT fails for the same callers. Master-only writes is the entire
    # point of the :public_read policy — a regression here would mean a
    # drive-by reader could tamper with catalog data.
    #
    # We narrow to +Parse::RecordNotSaved+ (the class +save!+ actually
    # raises — see {Parse::Core::Actions#save!} → autoraise branch in
    # +lib/parse/model/core/actions.rb+'s +save+) so a generic Ruby
    # exception raised BEFORE the HTTP attempt (NoMethodError,
    # ArgumentError) doesn't satisfy +assert_raises+ and mask a real
    # regression. The structural proof that the rejection came from the
    # server (not from a local validation short-circuit) is the
    # master-key reload at the end of this test asserting the field
    # was not mutated.
    as_client do
      bob = Parse::User.login(@bob.username, @bob_pw)
      via_bob = PublicReadCatalog.query
                                 .tap { |q| q.session_token = bob.session_token }
                                 .where(objectId: doc.id).first
      refute_nil via_bob, "non-owner must be able to fetch the row before attempting the write"
      via_bob.title = "tampered-by-bob"
      assert_raises(Parse::RecordNotSaved) do
        via_bob.save!(session: bob.session_token)
      end
    end

    as_client do
      via_no_session = PublicReadCatalog.query.where(objectId: doc.id).first
      refute_nil via_no_session
      via_no_session.title = "tampered-no-session"
      assert_raises(Parse::RecordNotSaved) do
        via_no_session.save!
      end
    end

    with_master_key do
      unchanged = PublicReadCatalog.find(doc.id)
      assert_equal "lookup", unchanged.title,
                   "no non-master write attempt may have landed on a :public_read row"
    end
  end

  # --------------------------------------------------------------------
  # :owner_but_public_read with a resolved owner — the post is publicly
  # readable but only the owner can write. Wire shape carries both
  # +"*" => {read: true}+ AND +<owner_id> => {read: true, write: true}+.
  # --------------------------------------------------------------------
  def test_owner_but_public_read_with_owner_grants_owner_write_only
    post = nil
    as_client do
      alice = Parse::User.login(@alice.username, @alice_pw)
      post = OwnerPublicReadPost.new(title: "by-alice", body: "v1", author: alice)
      assert post.save(session: alice.session_token),
             ":owner_but_public_read create by the owning user must succeed"
      @test_context.track(post)
    end

    with_master_key do
      fresh = OwnerPublicReadPost.find(post.id)
      perms = fresh.acl.permissions
      pub = perms["*"]
      refute_nil pub, ":owner_but_public_read must stamp a public entry"
      assert pub.read,  "public read must be granted"
      refute pub.write, "public write must NOT be granted"

      owner_entry = perms[@alice.id]
      refute_nil owner_entry, "owner ACL entry must be present (alice_id=#{@alice.id})"
      assert owner_entry.read,  "owner must have read"
      assert owner_entry.write, "owner must have write"
    end

    # Public read — bob (non-owner) and a no-session-token client both
    # succeed. (NOTE: "no session token" is a more accurate name than
    # "anonymous" — the request still carries the REST API key, so
    # Parse Server sees an app-key-authenticated caller, not truly
    # unauthenticated TCP traffic. The ACL behavior is equivalent for
    # these tests, but the distinction matters when reading the
    # assertion messages.)
    as_client do
      bob = Parse::User.login(@bob.username, @bob_pw)
      via_bob = OwnerPublicReadPost.query
                                   .tap { |q| q.session_token = bob.session_token }
                                   .where(objectId: post.id).first
      refute_nil via_bob, "non-owner must be able to read a public-read post"

      via_no_session = OwnerPublicReadPost.query.where(objectId: post.id).first
      refute_nil via_no_session, "no-session-token caller must be able to read a public-read post"
    end

    # Owner write — alice can update her own post.
    as_client do
      alice = Parse::User.login(@alice.username, @alice_pw)
      fetched = OwnerPublicReadPost.query
                                   .tap { |q| q.session_token = alice.session_token }
                                   .where(objectId: post.id).first
      fetched.body = "v2-by-owner"
      assert fetched.save(session: alice.session_token),
             "owner must be able to mutate her own :owner_but_public_read row"
    end

    # Non-owner write — bob is denied even though he can read.
    as_client do
      bob = Parse::User.login(@bob.username, @bob_pw)
      via_bob = OwnerPublicReadPost.query
                                   .tap { |q| q.session_token = bob.session_token }
                                   .where(objectId: post.id).first
      refute_nil via_bob, "non-owner must be able to fetch before attempting the write"
      via_bob.body = "tampered-by-bob"
      assert_raises(Parse::RecordNotSaved) do
        via_bob.save!(session: bob.session_token)
      end
    end

    # No-session-token write — also denied. (See note above on why
    # this is not literally "anonymous" — the REST API key is still
    # presented.)
    as_client do
      via_no_session = OwnerPublicReadPost.query.where(objectId: post.id).first
      refute_nil via_no_session
      via_no_session.body = "no-session-tamper"
      assert_raises(Parse::RecordNotSaved) do
        via_no_session.save!
      end
    end

    with_master_key do
      now = OwnerPublicReadPost.find(post.id)
      assert_equal "v2-by-owner", now.body,
                   "only the owner's update may have landed on the row"
    end
  end

  # --------------------------------------------------------------------
  # :owner_but_public_read with NO resolvable owner — the resolver falls
  # back to public-read semantics. The ACL on disk is the same shape as
  # a bare :public_read row (no owner key). This is the documented
  # fallback in {Parse::Object#_resolve_default_acl} — the +if owner_id+
  # guard skips the owner grant entirely when the owner field is unset.
  # --------------------------------------------------------------------
  def test_owner_but_public_read_without_owner_falls_back_to_public_read
    post = nil
    with_master_key do
      # Save with NO author set — the resolver finds owner_id == nil and
      # stamps only the public-read entry.
      post = OwnerPublicReadPost.new(title: "ownerless", body: "static")
      assert post.save,
             ":owner_but_public_read without owner must still save (master-key)"
      @test_context.track(post)

      fresh = OwnerPublicReadPost.find(post.id)
      perms = fresh.acl.permissions
      pub = perms["*"]
      refute_nil pub, "fallback must still stamp the public entry"
      assert pub.read,  "fallback must grant public read"
      refute pub.write, "fallback must NOT grant public write"
      assert_equal 1, perms.size,
                   "fallback shape must match :public_read exactly (single public entry), got: #{perms.inspect}"
    end

    # GET works for everyone, just like :public_read.
    as_client do
      bob = Parse::User.login(@bob.username, @bob_pw)
      via_bob = OwnerPublicReadPost.query
                                   .tap { |q| q.session_token = bob.session_token }
                                   .where(objectId: post.id).first
      refute_nil via_bob, "owner-less fallback row must be readable by a non-owner"

      anon = OwnerPublicReadPost.query.where(objectId: post.id).first
      refute_nil anon, "owner-less fallback row must be readable anonymously"
    end

    # No one can write — no owner was stamped, so the write ACL is empty.
    # +refute_nil+ on +via_alice+ FIRST: a regression that made the
    # fallback row unreadable would also fail the write attempt for the
    # wrong reason. Pin readability before pinning write rejection.
    as_client do
      alice = Parse::User.login(@alice.username, @alice_pw)
      via_alice = OwnerPublicReadPost.query
                                     .tap { |q| q.session_token = alice.session_token }
                                     .where(objectId: post.id).first
      refute_nil via_alice,
                 "fallback row must remain readable by an authenticated non-owner — " \
                 "if THIS fails, the write rejection below is masking a read regression"
      via_alice.body = "claim-by-alice"
      assert_raises(Parse::RecordNotSaved) do
        via_alice.save!(session: alice.session_token)
      end
    end

    with_master_key do
      unchanged = OwnerPublicReadPost.find(post.id)
      assert_equal "static", unchanged.body,
                   "no non-master write may have landed on the owner-less fallback row"
    end
  end
end
