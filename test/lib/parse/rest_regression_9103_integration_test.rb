require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"
require "securerandom"

# REST behaviors that changed across the Parse Server 9.10.x patch line and
# that the SDK relies on when it runs as an unprivileged client:
#
# - `_User` update validates `username` / `password` only when the body
#   carries them. An empty or null value is refused; an omitted key is not
#   touched.
# - A `_User` update is authorized before any step reads the target row. An
#   anonymous or cross-user update is refused and the target is unchanged.
# - A non-master `_Session` create honors the class's `create` and
#   `addField` CLP instead of writing with master authority unchecked.
#
# Every call here goes through a client with NO master key so the server's
# own enforcement is what gets asserted. Gated to Parse Server 9.10.3+, the
# integration baseline that ships these fixes.
class RestRegression9103IntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  MIN_SERVER_VERSION = "9.10.3"

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
    version = @master_client.server_version.to_s
    if version.empty? || Gem::Version.new(version[/\A[\d.]+/] || "0") < Gem::Version.new(MIN_SERVER_VERSION)
      skip "requires Parse Server #{MIN_SERVER_VERSION}+ (connected server reports #{version.inspect})"
    end
  end

  # ------------------------------------------------------------------
  # _User update: empty vs omitted credentials
  # ------------------------------------------------------------------

  def test_user_update_rejects_empty_username
    user, password = seed_client_user("rr_un")
    token = login_token(user, password)

    response = @no_master_client.update_user(user.id, { username: "" }, session_token: token)
    assert response.error?, "empty username must be refused"
    assert_equal 200, response.code, "expected USERNAME_MISSING (200), got #{response.inspect}"
    assert_equal user.username, master_fetch_user(user.id)["username"]
  end

  def test_user_update_rejects_null_username
    user, password = seed_client_user("rr_un_nil")
    token = login_token(user, password)

    response = @no_master_client.update_user(user.id, { username: nil }, session_token: token)
    assert response.error?, "null username must be refused"
    assert_equal 200, response.code
    assert_equal user.username, master_fetch_user(user.id)["username"]
  end

  def test_user_update_rejects_empty_password
    user, password = seed_client_user("rr_pw")
    token = login_token(user, password)

    response = @no_master_client.update_user(user.id, { password: "" }, session_token: token)
    assert response.error?, "empty password must be refused"
    assert_equal 201, response.code, "expected PASSWORD_MISSING (201), got #{response.inspect}"
    # The original password still logs in.
    refute_nil login_token(user, password)
  end

  def test_user_update_with_omitted_credentials_succeeds
    user, password = seed_client_user("rr_omit")
    token = login_token(user, password)

    response = @no_master_client.update_user(user.id, { nickname: "kept" }, session_token: token)
    assert response.success?, "update without username/password must succeed: #{response.inspect}"

    row = master_fetch_user(user.id)
    assert_equal "kept", row["nickname"]
    assert_equal user.username, row["username"], "omitted username must be left unchanged"
    refute_nil login_token(user, password), "omitted password must be left unchanged"
  end

  def test_user_update_with_new_password_succeeds
    user, password = seed_client_user("rr_newpw")
    token = login_token(user, password)
    new_password = "n3w-#{SecureRandom.hex(4)}"

    response = @no_master_client.update_user(user.id, { password: new_password }, session_token: token)
    assert response.success?, "a non-empty password change must succeed: #{response.inspect}"
    refute_nil login_token(user, new_password)
  end

  # ------------------------------------------------------------------
  # _User update: authorization
  # ------------------------------------------------------------------

  def test_cross_user_update_is_refused
    alice, alice_password = seed_client_user("rr_alice")
    bob, bob_password = seed_client_user("rr_bob")
    login_token(alice, alice_password)
    bob_token = login_token(bob, bob_password)

    response = @no_master_client.update_user(alice.id, { nickname: "hijacked" }, session_token: bob_token)
    assert response.error?, "Bob must not be able to update Alice"
    refute_equal "hijacked", master_fetch_user(alice.id)["nickname"]
  end

  def test_cross_user_update_cannot_change_credentials
    alice, alice_password = seed_client_user("rr_alice_pw")
    bob, bob_password = seed_client_user("rr_bob_pw")
    bob_token = login_token(bob, bob_password)

    response = @no_master_client.update_user(
      alice.id, { username: "taken_#{SecureRandom.hex(3)}", password: "x-#{SecureRandom.hex(3)}" },
      session_token: bob_token,
    )
    assert response.error?, "Bob must not be able to reset Alice's credentials"
    assert_equal alice.username, master_fetch_user(alice.id)["username"]
    refute_nil login_token(alice, alice_password), "Alice's password must be unchanged"
  end

  def test_anonymous_user_update_is_refused
    alice, = seed_client_user("rr_anon")

    response = @no_master_client.update_user(alice.id, { nickname: "anon" })
    assert response.error?, "an anonymous update must be refused"
    refute_equal "anon", master_fetch_user(alice.id)["nickname"]
  end

  def test_body_object_id_cannot_retarget_update
    alice, alice_password = seed_client_user("rr_retarget_a")
    bob, = seed_client_user("rr_retarget_b")
    alice_token = login_token(alice, alice_password)

    response = @no_master_client.update_user(
      alice.id, { objectId: bob.id, nickname: "retargeted" }, session_token: alice_token,
    )
    assert response.error?, "a body objectId that differs from the URL must be refused"
    refute_equal "retargeted", master_fetch_user(bob.id)["nickname"]
    refute_equal "retargeted", master_fetch_user(alice.id)["nickname"]
  end

  # ------------------------------------------------------------------
  # _Session create: CLP and addField
  # ------------------------------------------------------------------

  def test_session_create_requires_session_token
    response = @no_master_client.request(:post, "sessions", body: {})
    assert response.error?, "an anonymous session create must be refused"
    assert_equal 209, response.code
  rescue Parse::Error::InvalidSessionTokenError
    pass # the client raises on 209; either form proves the refusal
  end

  def test_session_create_honors_create_clp
    user, password = seed_client_user("rr_sess_create")
    token = login_token(user, password)

    with_session_clp("create" => {}) do
      response = @no_master_client.request(:post, "sessions", body: {}, opts: { session_token: token })
      assert response.error?, "a master-only create CLP must refuse a client session create"
      assert_equal 119, response.code

      response = @no_master_client.request(:post, "classes/_Session", body: {}, opts: { session_token: token })
      assert response.error?, "the /classes/_Session path must be refused the same way"
      assert_equal 119, response.code
    end
  end

  def test_session_create_honors_add_field_clp
    user, password = seed_client_user("rr_sess_field")
    token = login_token(user, password)
    field = "rrField#{SecureRandom.hex(3)}"

    with_session_clp("addField" => {}) do
      response = @no_master_client.request(:post, "sessions", body: { field => "x" },
                                                               opts: { session_token: token })
      assert response.error?, "a locked addField CLP must refuse a new _Session column"
      assert_equal 119, response.code

      fields = @master_client.schema("_Session").result["fields"] || {}
      refute fields.key?(field), "the refused column must not be added to the _Session schema"

      # A create that adds no column still works under the same CLP.
      response = @no_master_client.request(:post, "sessions", body: {}, opts: { session_token: token })
      assert response.success?, "a create without new columns must succeed: #{response.inspect}"
      assert_equal user.id, response.result.dig("user", "objectId")
    end
  end

  def test_session_create_ignores_client_supplied_user
    alice, alice_password = seed_client_user("rr_sess_owner")
    bob, = seed_client_user("rr_sess_other")
    token = login_token(alice, alice_password)

    body = { user: { __type: "Pointer", className: "_User", objectId: bob.id } }
    response = @no_master_client.request(:post, "sessions", body: body, opts: { session_token: token })
    assert response.success?, response.inspect
    assert_equal alice.id, response.result.dig("user", "objectId"),
                 "the new session must belong to the caller, not the client-supplied user"
  end

  private

  def login_token(user, password)
    response = @no_master_client.login(user.username, password)
    response.success? ? response.result["sessionToken"] : nil
  end

  def master_fetch_user(id)
    @master_client.fetch_user(id, use_master_key: true).result
  end

  # Apply a partial override on top of the open default `_Session` CLP, run
  # the block, and always restore the open default. `_Session` is a system
  # class, so the per-test database reset does not touch its CLP.
  def with_session_clp(overrides)
    open_clp = {
      "find" => { "*" => true }, "get" => { "*" => true }, "count" => { "*" => true },
      "create" => { "*" => true }, "update" => { "*" => true }, "delete" => { "*" => true },
      "addField" => { "*" => true }, "protectedFields" => { "*" => [] },
    }
    response = @master_client.update_schema("_Session", { classLevelPermissions: open_clp.merge(overrides) })
    assert response.success?, "could not set _Session CLP: #{response.inspect}"
    yield
  ensure
    @master_client.update_schema("_Session", { classLevelPermissions: open_clp })
  end
end
