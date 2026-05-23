require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"
require "securerandom"

# CRUD + queries + include + ACL isolation, all under a regular Parse
# client (no master key, session-token authentication, REST only).
#
# What this proves:
#   * Parse::Object#save / fetch / destroy work with session_token: ...
#   * Parse::Query#results / #count / .include(...) / .where(...) work
#     under session-token auth.
#   * ACL is enforced by Parse Server when reads come from a non-master
#     session — Bob cannot read Alice's private object.
#   * Convenience surfaces (Parse::User.login, current_user, .first,
#     .order, .limit) round-trip without master-key smuggling.
class ClientCrudPost < Parse::Object
  parse_class "ClientCrudPost"
  # Default SDK policy is :owner_else_private which, with no owner field
  # declared, stamps every save with an empty ACL ({} = master-key-only).
  # We want a publicly-readable post class for these CRUD tests so that
  # the assertions exercise CLP/auth behavior, not ACL fallthrough.
  acl_policy :public
  property :title, :string
  property :body, :string
  property :likes, :integer
  belongs_to :author, as: :user
end

class ClientCrudComment < Parse::Object
  parse_class "ClientCrudComment"
  acl_policy :public
  property :text, :string
  belongs_to :post, class_name: "ClientCrudPost"
  belongs_to :author, as: :user
end

class ClientRestCrudIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
    @alice, @alice_password = seed_client_user("alice")
    @bob,   @bob_password   = seed_client_user("bob")
  end

  # --------------------------------------------------------------------
  # Pre-flight: confirm the swap actually drops the master key. If this
  # ever regresses, every other assertion in the file passes for the
  # wrong reason.
  # --------------------------------------------------------------------
  def test_client_mode_strips_master_key
    as_client do
      assert_client_mode!
      assert_nil Parse::Client.client.master_key,
                 "no-master client must not carry a master key"
      refute_equal @master_client.object_id, Parse::Client.client.object_id,
                   "default client should be swapped to the no-master instance"
    end
  end

  # --------------------------------------------------------------------
  # Convenience: Parse::User.login returns a user with a live session.
  # --------------------------------------------------------------------
  def test_login_convenience_returns_authenticated_user
    as_client do
      user = Parse::User.login(@alice.username, @alice_password)
      refute_nil user, "Parse::User.login must return a user"
      refute_nil user.session_token, "login result must carry session_token"
      assert user.logged_in?, "user must report logged_in?"

      me = Parse.client.current_user(user.session_token)
      assert me.success?, "/users/me must accept the just-issued token"
      assert_equal @alice.id, me.result["objectId"]
    end
  end

  # --------------------------------------------------------------------
  # CREATE: save under session token, server assigns objectId, ACL is
  # whatever the client sent (public by default for this fixture class).
  # --------------------------------------------------------------------
  def test_create_under_session_token
    as_client do
      alice = Parse::User.login(@alice.username, @alice_password)

      post = ClientCrudPost.new(title: "hello", body: "first post", likes: 0, author: alice)
      assert post.save(session: alice.session_token),
             "client-mode save with session_token must succeed"
      refute_nil post.id, "server must assign objectId on save"

      # Anyone with the public-read default can read it back, including
      # via a fresh master-key fetch (sanity check the row exists).
      with_master_key do
        roundtrip = ClientCrudPost.find(post.id)
        assert_equal "hello", roundtrip.title
        assert_equal alice.id, roundtrip.author.id
      end
    end
  end

  # --------------------------------------------------------------------
  # READ / UPDATE / DESTROY under session token.
  # --------------------------------------------------------------------
  def test_read_update_destroy_under_session_token
    as_client do
      alice = Parse::User.login(@alice.username, @alice_password)

      post = ClientCrudPost.new(title: "v1", body: "x", likes: 1, author: alice)
      assert post.save(session: alice.session_token)

      fetched = ClientCrudPost.query.tap { |q| q.session_token = alice.session_token }
                              .where(objectId: post.id).first
      refute_nil fetched, "query under session token must find own object"
      assert_equal "v1", fetched.title

      fetched.title = "v2"
      assert fetched.save(session: alice.session_token), "update under session token must succeed"

      reread = ClientCrudPost.query.tap { |q| q.session_token = alice.session_token }
                             .where(objectId: post.id).first
      assert_equal "v2", reread.title

      assert reread.destroy(session: alice.session_token), "destroy under session token must succeed"

      with_master_key do
        assert_nil ClientCrudPost.find(post.id),
                   "row must be gone server-side after client-mode destroy"
      end
    end
  end

  # --------------------------------------------------------------------
  # Queries: where, order, limit, count — all under session token.
  # --------------------------------------------------------------------
  def test_query_where_order_limit_count
    as_client do
      alice = Parse::User.login(@alice.username, @alice_password)

      3.times do |i|
        ClientCrudPost.new(
          title: "p#{i}", body: "body #{i}", likes: i * 10, author: alice,
        ).save(session: alice.session_token)
      end

      q = ClientCrudPost.query.tap { |qq| qq.session_token = alice.session_token }
      results = q.where(:likes.gte => 10).order(:likes.desc).limit(5).results
      assert_equal [20, 10], results.map(&:likes),
                   "where/order/limit must compose under session-token query"

      cnt = ClientCrudPost.query
                          .tap { |qq| qq.session_token = alice.session_token }
                          .where(:likes.gt => 0)
                          .count
      assert_equal 2, cnt, "count must work under session token"
    end
  end

  # --------------------------------------------------------------------
  # Pointer expansion via .include — REST ?include=author.
  # --------------------------------------------------------------------
  def test_include_expands_pointer_under_session_token
    as_client do
      alice = Parse::User.login(@alice.username, @alice_password)

      post = ClientCrudPost.new(title: "with-author", author: alice).tap do |p|
        p.save(session: alice.session_token)
      end
      ClientCrudComment.new(text: "nice", post: post, author: alice).tap do |c|
        c.save(session: alice.session_token)
      end

      q = ClientCrudComment.query.tap { |qq| qq.session_token = alice.session_token }
      comment = q.where(text: "nice").include(:post, :author).first
      refute_nil comment

      refute_nil comment.post, "post pointer must be present"
      assert_equal "with-author", comment.post.title,
                   "include should expand the post pointer's fields"
      assert_equal alice.id, comment.author.id, "author pointer must round-trip"
    end
  end

  # --------------------------------------------------------------------
  # ACL isolation: Bob cannot read Alice's private object.
  # --------------------------------------------------------------------
  def test_acl_isolation_blocks_cross_user_read
    as_client do
      alice = Parse::User.login(@alice.username, @alice_password)
      private_post = ClientCrudPost.new(title: "secret", body: "shh", author: alice)
      private_post.acl.everyone(false, false)
      private_post.acl.apply(alice.id, true, true)
      assert private_post.save(session: alice.session_token)

      bob = Parse::User.login(@bob.username, @bob_password)
      seen = ClientCrudPost.query
                           .tap { |qq| qq.session_token = bob.session_token }
                           .where(objectId: private_post.id)
                           .first
      assert_nil seen, "Bob must not see Alice's ACL-private post"

      # Even a direct fetch by id from Bob's session is masked.
      via_get = Parse.client.fetch_object(
        ClientCrudPost.parse_class, private_post.id,
        session_token: bob.session_token, use_master_key: false,
      )
      assert via_get.error? || via_get.result.nil? || via_get.result.empty?,
             "direct GET as Bob must return error or empty for ACL-private row"
    end
  end

  # --------------------------------------------------------------------
  # ACL write isolation: Bob cannot modify Alice's writable-only-by-her
  # post even though he could (if granted) read it.
  # --------------------------------------------------------------------
  def test_acl_isolation_blocks_cross_user_write
    as_client do
      alice = Parse::User.login(@alice.username, @alice_password)
      readable = ClientCrudPost.new(title: "readable", body: "v1", author: alice)
      readable.acl.everyone(true, false)   # public read, no public write
      readable.acl.apply(alice.id, true, true)
      assert readable.save(session: alice.session_token)

      bob = Parse::User.login(@bob.username, @bob_password)
      fetched_as_bob = ClientCrudPost.query
                                     .tap { |qq| qq.session_token = bob.session_token }
                                     .where(objectId: readable.id).first
      refute_nil fetched_as_bob, "Bob should be able to READ a public-read post"

      fetched_as_bob.title = "tampered"
      # The save can surface as either a Parse::Error (server returned
      # an auth response) or Parse::RecordNotSaved (callback chain
      # halted because Parse Server replied "Object not found" — its
      # behavior when ACL denies write). Both are evidence the write
      # was rejected; the assertion is that SOMETHING refused it.
      err = assert_raises(Parse::Error, Parse::RecordNotSaved, StandardError) do
        fetched_as_bob.save!(session: bob.session_token)
      end
      assert_match(/forbidden|permission|acl|not allowed|not saved|object not found/i, err.message,
                   "save by non-writer must surface a permission/not-saved error, got: #{err.message}")

      # Confirm the row is unchanged.
      with_master_key do
        unchanged = ClientCrudPost.find(readable.id)
        assert_equal "readable", unchanged.title,
                     "unauthorized write must not have mutated the row"
      end
    end
  end
end
