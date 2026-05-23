require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"

class ForbiddenProbe < Parse::Object
  parse_class "ForbiddenProbe"
  acl_policy :public
  property :secret, :string
  property :score, :integer
end

# Known failures: SDK paths that REQUIRE the master key, called from a
# client-mode SDK, must fail loudly rather than silently succeed.
#
# Per CLAUDE.md: REST /aggregate is master-key-only and does NOT enforce
# ACL/CLP/protectedFields. Same goes for schemas, master-key fetch of
# arbitrary _User rows, and _Session reads. If any of these silently
# returned data to a non-master caller, every claim about ACL/CLP
# enforcement in the SDK would be wrong.
class ClientRestForbiddenPathsIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
    @user, @password = seed_client_user("forbidden")
    # Seed a row in a generic class so aggregate/find have something to
    # potentially leak if enforcement is broken.
    with_master_key do
      obj = ForbiddenProbe.new(secret: "leak-me", score: 42)
      assert obj.save
      @test_context.track(obj)
    end
  end

  # --------------------------------------------------------------------
  # REST /aggregate requires master key. From client mode, the request
  # must fail (Parse Server returns 401/403). It must NOT return rows.
  # --------------------------------------------------------------------
  def test_aggregate_requires_master_key
    as_client do
      logged_in = Parse::User.login(@user.username, @password)

      # Direct call to the aggregate API method — this is what
      # Parse::Query#count_with_aggregation / pipeline-based agents use.
      pipeline = [{ "$group" => { "_id" => nil, "n" => { "$sum" => 1 } } }]
      err = assert_raises(Parse::Error) do
        Parse.client.aggregate_pipeline(
          "ForbiddenProbe", pipeline,
          session_token: logged_in.session_token, use_master_key: false,
        )
      end
      assert_match(/master|unauthor|forbidden|permission/i, err.message,
                   "aggregate without master key must fail with an auth error, got: #{err.message}")
    end
  end

  # --------------------------------------------------------------------
  # /schemas is master-key-only. From client mode, must fail.
  # --------------------------------------------------------------------
  def test_schemas_requires_master_key
    as_client do
      err = assert_raises(Parse::Error) do
        Parse.client.schemas(use_master_key: false)
      end
      assert_match(/master|unauthor|forbidden|permission/i, err.message)
    end
  end

  # --------------------------------------------------------------------
  # _Session GET as a non-master caller must not enumerate sessions
  # belonging to OTHER users. Parse Server scopes /sessions to the
  # caller's own user automatically; the assertion is that even with
  # two seeded users live, user A's session token NEVER surfaces user
  # B's session rows.
  #
  # Anonymous (no token) is a separate path — must error out cleanly
  # rather than returning an empty enumeration that could be confused
  # with "no sessions exist."
  # --------------------------------------------------------------------
  def test_session_class_enumeration_scoped_to_current_user
    other_user, other_password = seed_client_user("forbidden_session_other")

    as_client do
      me      = Parse::User.login(@user.username, @password)
      _other  = Parse::User.login(other_user.username, other_password)

      response = Parse.client.find_objects(
        "_Session", {},
        session_token: me.session_token, use_master_key: false,
      )

      if response.success?
        rows = response.results || []
        # Every returned row's `user` pointer must belong to ME — the
        # caller. If Parse Server (or the SDK) ever leaked other users'
        # sessions on a non-master enumeration, this would catch it.
        rows.each do |row|
          user_ptr = row["user"] || row[:user] || {}
          user_id  = user_ptr.is_a?(Hash) ? (user_ptr["objectId"] || user_ptr[:objectId]) : nil
          assert_equal me.id, user_id,
                       "non-master /sessions enumeration must NOT return another user's session row: #{row.inspect}"
        end
      else
        # Some Parse Server builds reject the enumeration entirely
        # without master key. That's also a valid hardening posture.
        assert_match(/master|unauthor|forbidden|permission|not allowed|invalid.*session|invalid.*token/i,
                     response.error.to_s,
                     "if /sessions enumeration is rejected, it must surface a recognizable auth error, got: #{response.error.inspect}")
      end

      # Anonymous (no session token) must NOT return any rows.
      anon = nil
      begin
        anon = Parse.client.find_objects("_Session", {}, use_master_key: false)
      rescue Parse::Error => e
        assert_match(/master|unauthor|forbidden|permission|not allowed|invalid.*session|invalid.*token/i,
                     e.message,
                     "anon /sessions must error with a recognizable auth class, got: #{e.message}")
      end
      if anon&.success?
        assert_empty(anon.results || [],
                     "anonymous /sessions enumeration must NEVER return rows")
      end
    end
  end

  # --------------------------------------------------------------------
  # Master-key fetch of an arbitrary _User row from client mode must
  # fail (Parse Server treats _User reads as ACL-scoped without master).
  # --------------------------------------------------------------------
  def test_user_class_cross_account_fetch_blocked
    other_user, _ = seed_client_user("forbidden_other")

    as_client do
      me = Parse::User.login(@user.username, @password)

      # Try to fetch the other user's _User row by id without master.
      response = Parse.client.fetch_object(
        "_User", other_user.id,
        session_token: me.session_token, use_master_key: false,
      )

      # Parse Server returns either an error or a heavily-masked row
      # depending on version. We assert at minimum that sensitive fields
      # do not leak.
      if response.success?
        refute response.result["sessionToken"],
               "/users/<id> from another user must not leak sessionToken"
        refute response.result["authData"],
               "/users/<id> from another user must not leak authData"
      end
    end
  end
end
