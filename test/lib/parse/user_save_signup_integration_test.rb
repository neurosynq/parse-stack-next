require_relative "../../test_helper_integration"
require "securerandom"
require "timeout"

# Integration coverage for the signup-on-save behavior added in 4.0.1 and,
# in particular, the question of whether updating a non-credential field
# on an existing user invalidates that user's session.
#
# These hit a real Parse Server (Docker / localhost:2337) so they exercise
# both the gem's client wiring and Parse Server's actual auth bookkeeping.
class UserSaveSignupIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def with_timeout(seconds, description)
    Timeout.timeout(seconds) { yield }
  rescue Timeout::Error
    flunk "#{description} timed out after #{seconds} seconds"
  end

  # Helper: validate a session token against the server via /users/me.
  # Returns true iff Parse Server still considers the token live.
  def session_token_valid?(token)
    response = Parse.client.current_user(token)
    response.success?
  rescue Parse::Error
    false
  end

  # --------------------------------------------------------------------
  # Signup-on-save itself: a new user with password should come back
  # holding a session token issued by the signup endpoint.
  # --------------------------------------------------------------------
  def test_save_on_new_user_issues_real_session_token
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "new-user signup-on-save") do
        username = "su_new_#{SecureRandom.hex(4)}"
        user = Parse::User.new(username: username, password: "p4ssw0rd!", email: "#{username}@test.com")
        assert user.save, "Parse::User.new(...).save should succeed against real server"
        @test_context.track(user)

        refute_nil user.id, "user must have a server-assigned objectId"
        refute_nil user.session_token, "signup-on-save must populate session_token"
        assert user.logged_in?, "user should be logged_in? after signup-via-save"
        assert session_token_valid?(user.session_token),
               "session token from signup-via-save must be live on the server"
      end
    end
  end

  # --------------------------------------------------------------------
  # The core regression question: does saving a non-credential field on
  # an existing user invalidate the user's session?
  # --------------------------------------------------------------------
  def test_existing_user_save_does_not_invalidate_session
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "existing-user random-field save") do
        username = "su_keep_#{SecureRandom.hex(4)}"
        user = Parse::User.new(username: username, password: "p4ssw0rd!", email: "#{username}@test.com")
        assert user.save, "initial signup"
        @test_context.track(user)

        original_token = user.session_token
        refute_nil original_token
        assert session_token_valid?(original_token), "precondition: token live"

        # Mutate an unrelated field and save. This is exactly the
        # "user.save! on just a random field" scenario.
        user.email = "renamed_#{SecureRandom.hex(2)}@test.com"
        assert user.save(session: original_token),
               "save on existing user with random-field change should succeed"

        # In-memory token unchanged.
        assert_equal original_token, user.session_token,
                     "session_token must not be replaced/cleared by a random-field save"

        # Server-side token still live.
        assert session_token_valid?(original_token),
               "Parse Server must still accept the original session token after a random-field update"

        # And it actually maps back to the same user.
        me_response = Parse.client.current_user(original_token)
        assert me_response.success?
        assert_equal user.id, me_response.result["objectId"]
      end
    end
  end

  # --------------------------------------------------------------------
  # Bug investigated and fixed in 4.0.2: signup! / login! previously
  # left credential fields (password, username, email) marked dirty
  # because they called apply_attributes! on the response but never
  # changes_applied!. A subsequent user.save! re-sent `password` in the
  # update body, which Parse Server treats as a password change under
  # revokeSessionOnPasswordReset and revoked the just-issued session.
  #
  # These tests verify that signup! / login! now clear dirty state
  # internally, matching the behavior of Parse::Object#save.
  # --------------------------------------------------------------------

  def test_signup_bang_clears_dirty_state_for_credential_fields
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "signup! dirty-state clearing") do
        username = "su_clean_signup_#{SecureRandom.hex(4)}"
        user = Parse::User.new(username: username, password: "p4ssw0rd!", email: "#{username}@test.com")
        assert user.signup!
        @test_context.track(user)

        # After 4.0.2: signup! mirrors save's changes_applied! so the
        # credential fields are not left in the dirty set.
        refute_includes user.changed, "password",
                        "signup! must clear password from the dirty set"
        refute_includes user.changed, "username",
                        "signup! must clear username from the dirty set"
        refute_includes user.changed, "email",
                        "signup! must clear email from the dirty set"
        refute(user.attribute_updates.key?(:password) || user.attribute_updates.key?("password"),
               "attribute_updates must not still contain password after signup!")
      end
    end
  end

  def test_login_bang_clears_dirty_state_for_credential_fields
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "login! dirty-state clearing") do
        username = "su_clean_login_#{SecureRandom.hex(4)}"
        seed_user = Parse::User.new(username: username, password: "p4ssw0rd!", email: "#{username}@test.com")
        assert seed_user.save
        @test_context.track(seed_user)

        fresh = Parse::User.first(username: username)
        refute_nil fresh
        assert fresh.login!("p4ssw0rd!"), "login! should succeed"

        refute_includes fresh.changed, "password",
                        "login! must clear password from the dirty set"
        refute(fresh.attribute_updates.key?(:password) || fresh.attribute_updates.key?("password"),
               "attribute_updates must not contain password after login!")
      end
    end
  end

  def test_save_after_signup_bang_does_not_invalidate_session
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(20, "signup! + random-field save! preserves session") do
        username = "su_preserve_signup_#{SecureRandom.hex(4)}"
        user = Parse::User.new(username: username, password: "p4ssw0rd!", email: "#{username}@test.com")
        assert user.signup!
        @test_context.track(user)

        original_token = user.session_token
        refute_nil original_token
        assert session_token_valid?(original_token), "precondition: token live after signup!"

        # The cascade case: a random-field save after signup! used to
        # transmit the dirty `password` and revoke the session. 4.0.2
        # fixes this by clearing the dirty state inside signup!.
        user.email = "renamed_#{SecureRandom.hex(2)}@test.com"
        assert user.save(session: original_token)

        assert session_token_valid?(original_token),
               "save after signup! must not revoke the session that signup! just issued"
      end
    end
  end

  def test_save_after_login_bang_does_not_invalidate_session
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(25, "login! + random-field save! preserves session") do
        username = "su_preserve_login_#{SecureRandom.hex(4)}"
        seed = Parse::User.new(username: username, password: "p4ssw0rd!", email: "#{username}@test.com")
        assert seed.save
        @test_context.track(seed)

        fresh = Parse::User.first(username: username)
        assert fresh.login!("p4ssw0rd!")

        login_token = fresh.session_token
        refute_nil login_token
        assert session_token_valid?(login_token)

        fresh.email = "renamed_#{SecureRandom.hex(2)}@test.com"
        assert fresh.save(session: login_token)

        assert session_token_valid?(login_token),
               "save after login! must not revoke the session that login! just issued"
      end
    end
  end

  # --------------------------------------------------------------------
  # Sanity check: changing the *password* DOES invalidate the session
  # (Parse Server's revokeSessionOnPasswordReset behavior). Confirms our
  # other test isn't passing because the server simply never invalidates
  # User sessions on save.
  # --------------------------------------------------------------------
  def test_password_change_does_invalidate_session
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "password-change session invalidation") do
        username = "su_pw_#{SecureRandom.hex(4)}"
        user = Parse::User.new(username: username, password: "old_p4ss!", email: "#{username}@test.com")
        assert user.save
        @test_context.track(user)

        original_token = user.session_token
        refute_nil original_token
        assert session_token_valid?(original_token), "precondition: token live"

        user.password = "new_p4ss!"
        assert user.save(session: original_token), "password change save should succeed"

        # Parse Server's default revokeSessionOnPasswordReset=true revokes
        # all other sessions; whichever session performed the password
        # change is what the server typically keeps. We don't assert
        # which side survives — only that this DOES touch session state,
        # whereas the random-field test above does not.
        post_change_live = session_token_valid?(original_token)
        new_token        = user.session_token

        # Either the original was invalidated, or the server rotated us
        # onto a new token. Both are evidence the server is auth-aware
        # of password changes (and the random-field test isn't a no-op).
        assert(!post_change_live || new_token != original_token,
               "password change should either invalidate the original token or rotate session_token")
      end
    end
  end

  # --------------------------------------------------------------------
  # 4.1.1: signup-on-save + parse_reference (default precompute: false)
  # used to crash Parse Server 9 with
  #   Value is non of these types TypedArray<u8>, String
  # at password.js:18 in @node-rs/bcrypt. The after_create
  # `_assign_parse_reference!` callback issues an `update!` from inside
  # the `run_callbacks :create` block, and `attribute_updates` carried
  # `password` as dirty with a nil current value — serialized as
  # `{ password: { "__op": "Delete" } }`. Parse Server's _User write
  # path fed that hash to the rust bcrypt binding, which rejects
  # anything that isn't a string or u8 buffer.
  #
  # Fix in 4.1.1: signup_create runs `changes_applied!` +
  # `clear_partial_fetch_state!` right after applying the response, so
  # by the time the after_create chain runs the dirty set is empty and
  # the follow-up PUT only carries `parseReference`.
  # --------------------------------------------------------------------
  class UserWithParseReference < Parse::User
    parse_class Parse::Model::CLASS_USER
    # Parse::Object#fields is a class-instance variable that is copied
    # from Parse::Object on first access (not from the immediate
    # superclass), so a User subclass does not auto-inherit the
    # username/password/email property declarations. Re-declare them so
    # `attribute_updates` produces a real signup body.
    property :auth_data, :object
    property :email
    property :password
    property :username
    parse_reference
  end

  def test_signup_on_save_with_parse_reference_subclass_succeeds
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "signup-on-save + parse_reference subclass") do
        username = "su_pref_#{SecureRandom.hex(4)}"
        user = UserWithParseReference.new(
          username: username,
          password: "p4ssw0rd!",
          email: "#{username}@test.com",
        )
        # Pre-4.1.1 this raised Parse::Client::ResponseError carrying the
        # bcrypt rust binding TypeError. After the fix, the after_create
        # update!  sends only parseReference and the save succeeds.
        assert user.save!, "save! on parse_reference User subclass must succeed"
        @test_context.track(user)

        refute_nil user.id, "user must have an objectId after signup"
        refute_nil user.session_token, "signup-on-save must populate session_token"
        assert session_token_valid?(user.session_token),
               "session token must remain live (no bcrypt rehash path triggered)"

        expected_ref = "#{Parse::Model::CLASS_USER}$#{user.id}"
        assert_equal expected_ref, user.parse_reference,
                     "parse_reference must be populated via the after_create update!"

        # Confirm Parse Server actually persisted the reference column.
        # Read the raw row back through the client (the Parse::User
        # subclass redispatches to plain Parse::User on build because
        # parse_class is shared, so query through the raw fetch path).
        raw = Parse.client.fetch_object("_User", user.id, opts: { use_master_key: true })
        assert raw.success?, "master-key fetch of new user must succeed"
        assert_equal expected_ref, raw.result["parseReference"],
                     "parseReference column must be persisted server-side"
      end
    end
  end

  def test_signup_on_save_with_parse_reference_clears_password_dirty_state
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "signup-on-save clears password dirty state") do
        username = "su_pref_clean_#{SecureRandom.hex(4)}"
        user = UserWithParseReference.new(
          username: username,
          password: "p4ssw0rd!",
          email: "#{username}@test.com",
        )
        assert user.save!
        @test_context.track(user)

        # The after_create update! must NOT include password under any
        # form (raw value, nil, or { __op: "Delete" }).
        refute_includes user.changed, "password",
                        "password must not be in the dirty set after signup-on-save"
        updates = user.attribute_updates
        refute(updates.key?(:password) || updates.key?("password"),
               "attribute_updates must not contain password after signup-on-save")
      end
    end
  end
end
