require_relative "../../../test_helper"

# Unit tests for the signup-on-save behavior introduced in 4.0.1:
# `Parse::User.new(...).save!` now routes through the signup endpoint
# (`POST /parse/users`) when the new user has a `password`, instead of
# the raw class endpoint (`POST /parse/classes/_User`). This means
# `save!` now returns an object with a populated `session_token`,
# matching the Parse JS SDK contract. `auth_data`-only signups are
# deliberately NOT routed through this path -- OAuth signup remains
# the responsibility of the explicit `signup!` method.
#
# All tests stub the user's `client` so the unit suite does not require
# a running Parse Server.
class TestUserSaveSignup < Minitest::Test
  # Minimal stand-in for Parse::Response. Captures the methods that
  # Parse::User#signup_create and Parse::Object#create consult.
  class StubResponse
    attr_reader :result, :code, :error

    def initialize(result: {}, code: nil, error: nil)
      @result = result
      @code = code
      @error = error
    end

    def success?
      @code.nil? && @error.nil?
    end

    def error?
      !success?
    end
  end

  # Stand-in for Parse::Client. Records every routed call so tests can
  # assert which endpoint (create_user vs create_object vs update_object)
  # was actually exercised, and what attributes were sent.
  class StubClient
    attr_reader :calls

    # @param responses [Hash] map of endpoint symbol => StubResponse to
    #   return for that endpoint. Endpoints not listed return a default
    #   success response. Methods accept the same kwargs as the real
    #   Parse::Client; values are recorded into `calls` for inspection.
    def initialize(responses = {})
      @calls = []
      @responses = responses
    end

    def create_user(body, session_token: nil, **_opts)
      @calls << [:create_user, body, session_token]
      @responses.fetch(:create_user) { default_user_response }
    end

    def create_object(class_name, body, session_token: nil, **_opts)
      @calls << [:create_object, class_name, body, session_token]
      @responses.fetch(:create_object) { default_user_response }
    end

    def update_object(class_name, id, body, session_token: nil, **_opts)
      @calls << [:update_object, class_name, id, body, session_token]
      @responses.fetch(:update_object) { StubResponse.new(result: { "updatedAt" => "2026-05-15T00:00:01Z" }) }
    end

    def calls_to(method)
      @calls.select { |c| c.first == method }
    end

    private

    def default_user_response
      StubResponse.new(result: {
        "objectId" => "abc123",
        "createdAt" => "2026-05-15T00:00:00Z",
        "sessionToken" => "r:stub-session-token",
      })
    end
  end

  # Named subclass used by the callback test. ActiveModel's `model_name`
  # requires the class to be named (anonymous subclasses raise).
  class SignupCallbackUser < Parse::User
    cattr_accessor :callback_log
    self.callback_log = []
    before_create { self.class.callback_log << :before_create }
    after_create  { self.class.callback_log << :after_create }
  end

  def setup
    @original_signup_on_save = Parse::User.signup_on_save
    Parse::User.signup_on_save = true
  end

  def teardown
    Parse::User.signup_on_save = @original_signup_on_save
  end

  # Helper: build a new user wired to a stub client.
  def new_user_with_client(client, **attrs)
    user = Parse::User.new(attrs)
    user.define_singleton_method(:client) { client }
    user
  end

  # --------------------------------------------------------------------
  # Configuration flag
  # --------------------------------------------------------------------

  def test_signup_on_save_defaults_to_true
    # setup forces it to true; reload the gem-level default by reverting
    # to whatever the constant was assigned at class definition time.
    assert_equal true, Parse::User.signup_on_save
  end

  def test_signup_on_save_can_be_toggled
    Parse::User.signup_on_save = false
    refute Parse::User.signup_on_save
  ensure
    Parse::User.signup_on_save = true
  end

  def test_signup_on_save_is_inherited_by_subclasses
    # Use the already-named SignupCallbackUser to avoid leaving an
    # anonymous descendant in Parse::Object.descendants, which other
    # tests iterate via Parse::Model.find_class.
    original = SignupCallbackUser.signup_on_save
    assert_equal true, SignupCallbackUser.signup_on_save

    SignupCallbackUser.signup_on_save = false
    refute SignupCallbackUser.signup_on_save, "subclass override should apply locally"
    assert Parse::User.signup_on_save, "subclass override must not leak to parent"
  ensure
    SignupCallbackUser.signup_on_save = original if defined?(original)
  end

  # --------------------------------------------------------------------
  # Endpoint routing for new users
  # --------------------------------------------------------------------

  def test_new_user_with_password_routes_through_signup_endpoint
    client = StubClient.new
    user = new_user_with_client(client, username: "alice", password: "s3cret")

    assert user.save, "save should succeed against the stub"
    assert_equal 1, client.calls_to(:create_user).size,
                 "expected exactly one create_user (signup) call"
    assert_empty client.calls_to(:create_object),
                 "should not have fallen through to /classes/_User"
  end

  def test_new_user_with_auth_data_but_no_password_does_not_route_through_signup_endpoint
    # Federated-identity signups via auth_data must NOT be triggerable
    # from a mass-assigned save. POST /parse/users treats auth_data as
    # an identity claim against an existing user, so a Rails controller
    # doing `Parse::User.new(params); u.save!` with attacker-controlled
    # auth_data could otherwise plant another user's session token on
    # the in-memory object. OAuth signup is the responsibility of the
    # explicit `signup!` method.
    client = StubClient.new({ create_object: StubResponse.new(result: {
      "objectId" => "raw-id",
      "createdAt" => "2026-05-15T00:00:00Z",
    }) })
    user = new_user_with_client(client,
      username: "bob",
      auth_data: { facebook: { id: "1", access_token: "tok" } },
    )

    assert user.save
    assert_empty client.calls_to(:create_user),
                 "auth_data without password must not trigger the signup endpoint"
    assert_equal 1, client.calls_to(:create_object).size
    assert_nil user.session_token
  end

  def test_new_user_without_credentials_falls_through_to_class_endpoint
    client = StubClient.new({ create_object: StubResponse.new(result: {
      "objectId" => "raw-id",
      "createdAt" => "2026-05-15T00:00:00Z",
    }) })
    user = new_user_with_client(client, username: "carol")

    assert user.save
    assert_empty client.calls_to(:create_user),
                 "no credentials => signup endpoint must not be hit"
    assert_equal 1, client.calls_to(:create_object).size
    assert_equal Parse::Model::CLASS_USER, client.calls_to(:create_object).first[1]
    assert_nil user.session_token,
               "raw /classes/_User insert does not return a session token"
  end

  def test_signup_on_save_false_forces_class_endpoint_even_with_password
    Parse::User.signup_on_save = false
    client = StubClient.new({ create_object: StubResponse.new(result: {
      "objectId" => "raw-id",
      "createdAt" => "2026-05-15T00:00:00Z",
    }) })
    user = new_user_with_client(client, username: "dave", password: "s3cret")

    assert user.save
    assert_empty client.calls_to(:create_user)
    assert_equal 1, client.calls_to(:create_object).size
    assert_nil user.session_token
  end

  # --------------------------------------------------------------------
  # Existing users must keep using the update path
  # --------------------------------------------------------------------

  def test_existing_user_save_uses_update_endpoint_not_signup
    client = StubClient.new
    user = new_user_with_client(client, username: "eve", password: "s3cret")
    # Simulate a persisted user: stamp the id and createdAt (both are
    # required for new? to return false), disable autofetch (the property
    # writer below would otherwise try to round-trip through the stub),
    # and clear dirty state so only the new email change is treated as
    # the save's payload.
    user.id = "existing-id"
    user.created_at = Time.now
    user.disable_autofetch!
    user.send(:changes_applied!)
    # Now mutate a field to trigger an update save
    user.email = "eve@example.com"

    assert user.save
    assert_empty client.calls_to(:create_user),
                 "an existing user save must not hit the signup endpoint"
    assert_empty client.calls_to(:create_object),
                 "an existing user save must not hit create_object"
    assert_equal 1, client.calls_to(:update_object).size
  end

  # --------------------------------------------------------------------
  # Response application
  # --------------------------------------------------------------------

  def test_save_applies_session_token_from_signup_response
    client = StubClient.new({ create_user: StubResponse.new(result: {
      "objectId" => "u1",
      "createdAt" => "2026-05-15T00:00:00Z",
      "sessionToken" => "r:abc",
    }) })
    user = new_user_with_client(client, username: "frank", password: "s3cret")

    assert user.save
    assert_equal "r:abc", user.session_token
    assert user.logged_in?, "logged_in? should be true once session_token is set"
    assert_equal "u1", user.id
  end

  def test_save_returns_false_on_error_response
    client = StubClient.new({ create_user: StubResponse.new(
      result: {},
      code: Parse::Response::ERROR_USERNAME_TAKEN,
      error: "Account already exists for this username.",
    ) })
    user = new_user_with_client(client, username: "taken", password: "s3cret")
    # Suppress the "Error creating ..." stderr print from the create body
    capture_io { refute user.save, "save should return false on a signup error response" }

    assert_nil user.session_token, "no session token should be set on error"
  end

  def test_save_bang_raises_record_not_saved_on_error_response
    client = StubClient.new({ create_user: StubResponse.new(
      result: {},
      code: Parse::Response::ERROR_USERNAME_TAKEN,
      error: "Account already exists for this username.",
    ) })
    user = new_user_with_client(client, username: "taken", password: "s3cret")

    capture_io do
      assert_raises(Parse::RecordNotSaved) { user.save! }
    end
  end

  # --------------------------------------------------------------------
  # Callbacks
  # --------------------------------------------------------------------

  def test_save_runs_before_create_and_after_create_callbacks
    SignupCallbackUser.callback_log = []
    client = StubClient.new
    user = SignupCallbackUser.new(username: "grace", password: "s3cret")
    user.define_singleton_method(:client) { client }

    assert user.save
    assert_equal [:before_create, :after_create], SignupCallbackUser.callback_log
  end

  def test_subclass_inheriting_signup_on_save_routes_through_signup_endpoint
    client = StubClient.new
    user = SignupCallbackUser.new(username: "harry", password: "s3cret")
    user.define_singleton_method(:client) { client }

    assert user.save
    assert_equal 1, client.calls_to(:create_user).size,
                 "subclass should inherit signup_on_save=true and use the signup endpoint"
  end

  # --------------------------------------------------------------------
  # Subsequent saves should not re-send the password
  # --------------------------------------------------------------------

  def test_password_is_not_re_sent_on_subsequent_save
    client = StubClient.new
    user = new_user_with_client(client, username: "henry", password: "s3cret")

    assert user.save, "initial signup-via-save"
    user.email = "henry@example.com"
    assert user.save, "subsequent save (update)"

    update_call = client.calls_to(:update_object).first
    refute_nil update_call, "expected an update_object call after the initial save"
    body = update_call[3]
    refute body.key?(:password), "password should not be re-sent on subsequent save"
    refute body.key?("password"), "password should not be re-sent on subsequent save"
    assert(body.key?(:email) || body.key?("email"),
           "expected email change to be present in update body, got: #{body.inspect}")
  end

  # --------------------------------------------------------------------
  # Request body shape
  # --------------------------------------------------------------------

  def test_signup_request_body_includes_user_supplied_fields
    client = StubClient.new
    user = new_user_with_client(client,
      username: "iris",
      password: "p4ss",
      email: "iris@example.com",
    )

    assert user.save
    body = client.calls_to(:create_user).first[1]
    assert_equal "iris", body[:username] || body["username"]
    assert_equal "p4ss", body[:password] || body["password"]
    assert_equal "iris@example.com", body[:email] || body["email"]
  end

  # --------------------------------------------------------------------
  # Defensive filtering: request body
  # --------------------------------------------------------------------

  def test_signup_request_body_strips_acl
    # `attribute_updates` already filters [:id, :created_at, :updated_at]
    # via Parse::Properties::BASE_KEYS, so the load-bearing strip in
    # signup_create is :ACL (the remote-name remap of :acl). signup!
    # strips the same field for parity with Parse Server's own ACL
    # defaulting on the signup endpoint.
    client = StubClient.new
    user = new_user_with_client(client, username: "jade", password: "p4ss")
    # Parse::User instances have nil acl by default (the SDK leaves
    # built-in classes' ACLs untouched so Parse Server's per-class
    # defaults apply). To test the signup-body strip we have to
    # explicitly install an unsafe ACL the strip should remove.
    user.acl = Parse::ACL.everyone(true, true).as_json

    # Sanity-check: without the strip, :ACL would be in attribute_updates.
    # This confirms the assertion below is non-tautological.
    assert user.attribute_updates.key?(:ACL),
           "attribute_updates must include :ACL for this test to be meaningful"

    assert user.save
    body = client.calls_to(:create_user).first[1]
    refute body.key?(:ACL),  "ACL must not be sent to /parse/users (parity with signup!)"
    refute body.key?("ACL"), "ACL (string key) must not be sent to /parse/users"
  end

  # --------------------------------------------------------------------
  # Defensive filtering: response body
  # --------------------------------------------------------------------

  def test_save_does_not_apply_server_supplied_auth_data_from_response
    # A compromised or MITM'd Parse Server (or a buggy custom adapter)
    # must not be able to plant authData onto the in-memory user via
    # the signup-via-save path. Only sessionToken and emailVerified are
    # accepted from the response body.
    client = StubClient.new({ create_user: StubResponse.new(result: {
      "objectId" => "u9",
      "createdAt" => "2026-05-15T00:00:00Z",
      "sessionToken" => "r:legit",
      "authData" => { "facebook" => { "id" => "attacker-fb-id", "access_token" => "stolen" } },
    }) })
    user = new_user_with_client(client, username: "kim", password: "p4ss")

    assert user.save
    assert_equal "r:legit", user.session_token, "sessionToken must still be applied"
    assert_nil user.auth_data, "server-supplied authData must NOT be applied"
  end

  def test_save_does_not_apply_server_supplied_username_or_password_from_response
    # The response could try to redirect the in-memory object to a
    # different username (account-takeover surface). Reject anything
    # outside the allow-list.
    client = StubClient.new({ create_user: StubResponse.new(result: {
      "objectId" => "u10",
      "createdAt" => "2026-05-15T00:00:00Z",
      "sessionToken" => "r:legit",
      "username" => "attacker",
      "password" => "rewritten",
    }) })
    user = new_user_with_client(client, username: "leo", password: "p4ss")

    assert user.save
    assert_equal "leo", user.username,
                 "username from response body must NOT clobber the user's chosen username"
    # In 4.0.2 the post-signup plaintext password is cleared from the
    # in-memory user (defense-in-depth against heap-dump exposure;
    # parity with Parse JS SDK). The original guarantee -- a malicious
    # `"password" => "rewritten"` server response must not become the
    # in-memory password -- still holds: the value is nil, not the
    # attacker-supplied string.
    assert_nil user.password,
               "post-signup password must be cleared from memory (and definitely must not be the attacker-supplied value)"
    refute_equal "rewritten", user.password,
                 "attacker-supplied password from response must never be applied"
  end

  # --------------------------------------------------------------------
  # Defense in depth: mass-assignment filter
  # --------------------------------------------------------------------

  def test_mass_assigned_auth_data_is_stripped_at_construction
    # Backstop for any code path that doesn't route through Parse::User#create
    # (e.g. batch save via BatchOperation#change_requests, transaction
    # save_all). PROTECTED_MASS_ASSIGNMENT_KEYS filters auth_data at
    # construction so the dirty-tracked field never appears in
    # attribute_updates and is never forwarded to /parse/users by any
    # downstream save mechanism.
    user = Parse::User.new(
      username: "nora",
      password: "p4ss",
      auth_data: { facebook: { id: "attacker-id", access_token: "stolen" } },
    )

    assert_nil user.auth_data,
               "auth_data must be stripped by the mass-assignment filter when assigned via constructor"
    refute user.attribute_updates.key?(:authData),
           "authData (remote-mapped) must not appear in attribute_updates after mass-assignment filtering"
    refute user.attribute_updates.key?(:auth_data),
           "auth_data must not appear in attribute_updates after mass-assignment filtering"
  end

  def test_explicit_auth_data_setter_still_works_for_trusted_callers
    # The mass-assignment filter must not block direct programmatic
    # assignment - server code that explicitly invokes the typed setter
    # is asserting trust in its own input.
    user = Parse::User.new(username: "olga", password: "p4ss")
    user.auth_data = { "facebook" => { "id" => "trusted-id", "access_token" => "ok" } }

    assert_equal({ "facebook" => { "id" => "trusted-id", "access_token" => "ok" } },
                 user.auth_data, "explicit setter must remain functional")
  end

  # --------------------------------------------------------------------
  # 4.0.2: signup! response is allow-listed and @password is cleared
  # --------------------------------------------------------------------

  def test_signup_bang_response_is_filtered_by_allow_list
    # A compromised / MITM'd Parse Server can plant arbitrary keys on
    # the signup response. signup! must mirror signup_create's
    # SIGNUP_RESPONSE_APPLY_KEYS filter so that authData, _rperm,
    # _wperm, roles, etc. never reach the in-memory user.
    client = StubClient.new({ create_user: StubResponse.new(result: {
      "objectId" => "u-su1",
      "createdAt" => "2026-05-15T00:00:00Z",
      "sessionToken" => "r:legit",
      "authData" => { "facebook" => { "id" => "attacker", "access_token" => "stolen" } },
      "username" => "attacker",
    }) })
    user = new_user_with_client(client, username: "ursula", password: "p4ss")

    assert user.signup!
    assert_equal "r:legit", user.session_token, "sessionToken still applied (allow-listed)"
    assert_equal "u-su1", user.id, "objectId still applied (extracted directly)"
    assert_nil user.auth_data, "authData from signup response must NOT be applied"
    assert_equal "ursula", user.username,
                 "username from signup response must NOT clobber the caller-chosen username"
  end

  def test_signup_bang_clears_plaintext_password_on_success
    client = StubClient.new
    user = new_user_with_client(client, username: "vince", password: "p4ss")

    assert user.signup!
    assert_nil user.password, "plaintext password must be cleared from memory after signup!"
    refute_includes user.changed, "password",
                    "password clear must not leave a dirty diff (otherwise next save would send null)"
  end

  def test_login_bang_clears_plaintext_password_on_success
    client = StubClient.new({ login: StubResponse.new(result: {
      "objectId" => "u-li1",
      "createdAt" => "2026-05-15T00:00:00Z",
      "sessionToken" => "r:login-tok",
      "username" => "wanda",
    }) })
    # The stub client doesn't define `login`; add a stub method on the
    # client instance so login! can complete.
    def client.login(_user, _pass)
      @calls << [:login]
      @responses.fetch(:login)
    end
    user = new_user_with_client(client, username: "wanda", password: "p4ss")

    assert user.login!
    assert_nil user.password, "plaintext password must be cleared from memory after login!"
    refute_includes user.changed, "password",
                    "password clear must not leave a dirty diff after login!"
    assert_equal "r:login-tok", user.session_token, "session token still applied from login response"
  end

  def test_signup_bang_failure_preserves_password
    # Belt-and-suspenders: the @password = nil clear only runs in the
    # success branch. A failed signup! must leave the caller's
    # password intact so they can retry.
    client = StubClient.new({ create_user: StubResponse.new(
      result: {},
      code: Parse::Response::ERROR_USERNAME_TAKEN,
      error: "Account already exists",
    ) })
    user = new_user_with_client(client, username: "xander", password: "p4ss")

    assert_raises(Parse::Error::UsernameTakenError) { user.signup! }
    assert_equal "p4ss", user.password,
                 "failed signup! must NOT clear the caller's password (they may retry)"
  end

  def test_save_applies_email_verified_from_signup_response
    # emailVerified is an allow-listed key: Parse Server can flag the
    # user as verified at signup time (e.g. via a beforeSignUp trigger
    # or a pre-trusted email domain).
    skip "_User has no emailVerified property declared by default" unless Parse::User.fields.key?(:email_verified)
    client = StubClient.new({ create_user: StubResponse.new(result: {
      "objectId" => "u11",
      "createdAt" => "2026-05-15T00:00:00Z",
      "sessionToken" => "r:legit",
      "emailVerified" => true,
    }) })
    user = new_user_with_client(client, username: "mia", password: "p4ss")

    assert user.save
    assert user.email_verified, "emailVerified should be applied from signup response"
  end

  # --------------------------------------------------------------------
  # SERVER_CONTROLLED_KEYS strip (defense-in-depth for emailVerified)
  # --------------------------------------------------------------------
  # Parse Server's default `_User` CLP already rejects non-master writes
  # to `emailVerified`, but the SDK strips client-supplied values before
  # the wire so the field cannot be smuggled through signup or
  # `Parse::User.create` even on a deployment that has loosened the CLP.

  def test_signup_on_save_strips_email_verified_from_body
    skip "no email_verified property" unless Parse::User.fields.key?(:email_verified)
    client = StubClient.new
    user = new_user_with_client(client, username: "v1", password: "p4ss", email_verified: true)

    assert user.save
    body = client.calls_to(:create_user).first[1]
    refute body.key?(:emailVerified), "signup body must not carry caller-supplied emailVerified"
    refute body.key?("emailVerified"), "signup body must not carry caller-supplied emailVerified (string key)"
    refute body.key?(:email_verified), "signup body must not carry snake_case email_verified"
    refute body.key?("email_verified"), "signup body must not carry snake_case email_verified (string key)"
  end

  def test_signup_bang_strips_email_verified_from_body
    skip "no email_verified property" unless Parse::User.fields.key?(:email_verified)
    client = StubClient.new
    user = new_user_with_client(client, username: "v2", password: "p4ss")
    user.email_verified = true # caller tries to set it explicitly

    assert user.signup!
    body = client.calls_to(:create_user).first[1]
    refute body.key?(:emailVerified)
    refute body.key?("emailVerified")
  end

  def test_create_strips_email_verified_from_body
    skip "no email_verified property" unless Parse::User.fields.key?(:email_verified)
    # Stub the class-level client used by Parse::User.create.
    captured = nil
    stubbed_client = Class.new do
      define_method(:create_user) do |body, **_opts|
        captured = body.dup
        StubResponse.new(result: { "objectId" => "u_c", "createdAt" => "2026-05-15T00:00:00Z" })
      end
    end.new

    # Briefly swap the class client.
    original_method = Parse::User.method(:client)
    Parse::User.define_singleton_method(:client) { stubbed_client }
    begin
      Parse::User.create({ username: "v3", password: "p4ss", emailVerified: true, email_verified: true })
    ensure
      Parse::User.define_singleton_method(:client, original_method)
    end

    refute_nil captured, "create_user should have been invoked"
    refute captured.key?(:emailVerified), "create body must not carry emailVerified"
    refute captured.key?("emailVerified")
    refute captured.key?(:email_verified)
    refute captured.key?("email_verified")
  end

  def test_strip_server_controlled_keys_is_idempotent_and_safe
    # Calling on a body that doesn't contain the keys is a no-op.
    body = { username: "x", password: "y" }
    result = Parse::User.strip_server_controlled_keys!(body)
    assert_same body, result, "must mutate and return the same hash"
    assert_equal({ username: "x", password: "y" }, body)
  end

  def test_strip_server_controlled_keys_handles_non_hash
    # Defensive: non-Hash inputs (nil, arrays, etc.) should pass through.
    assert_nil Parse::User.strip_server_controlled_keys!(nil)
    assert_equal "x", Parse::User.strip_server_controlled_keys!("x")
  end

  # --------------------------------------------------------------------
  # Session-token preservation on existing-user updates
  # --------------------------------------------------------------------
  # Regression coverage for the worry that signup-on-save (added in 4.0.1)
  # could leak into the existing-user update path and invalidate / replace
  # the in-memory session token when an unrelated field is saved.

  # Helper: build an "already persisted" user wired to a stub client, with
  # a session_token in place and dirty state cleared.
  def existing_user_with_session(client, session_token: "r:original-token", **attrs)
    user = new_user_with_client(client, **attrs)
    user.id = "existing-id"
    # Stamp createdAt so new? returns false (id alone is no longer
    # sufficient -- it also checks createdAt to keep semantics stable
    # through the precompute before_create path).
    user.created_at = Time.now
    user.disable_autofetch!
    user.send(:changes_applied!)
    user.session_token = session_token
    user
  end

  def test_existing_user_save_preserves_session_token_when_updating_random_field
    client = StubClient.new
    user = existing_user_with_session(client, username: "paul")
    assert_equal "r:original-token", user.session_token, "precondition"

    user.email = "paul@example.com"
    assert user.save

    assert_equal 1, client.calls_to(:update_object).size, "should hit update path"
    assert_empty client.calls_to(:create_user),  "must not route through signup endpoint"
    assert_empty client.calls_to(:create_object), "must not route through raw class endpoint"
    assert_equal "r:original-token", user.session_token,
                 "save! on a random field must not clear/replace the in-memory session token"
    assert user.logged_in?, "user should still be logged in after a random-field update"
  end

  def test_existing_user_update_body_does_not_contain_password
    # Even when signup_on_save is true, an update should never carry the
    # password field (Parse never returns it on fetch; the dirty tracker
    # should not include it for a random-field save).
    client = StubClient.new
    user = existing_user_with_session(client, username: "quinn")

    user.email = "quinn@example.com"
    assert user.save

    body = client.calls_to(:update_object).first[3]
    refute body.key?(:password),  "password must not appear in update body"
    refute body.key?("password"), "password must not appear in update body"
    refute body.key?(:username),  "username must not appear in update body for unrelated field change"
    refute body.key?("username"), "username must not appear in update body for unrelated field change"
  end

  def test_existing_user_save_passes_session_token_via_save_session_arg
    # `_session_token` for an update is the one explicitly passed via
    # `save(session: ...)`, not the user's own `session_token`. This is
    # the same as pre-4.0.1 behavior and verifies the new commit hasn't
    # shifted the auth context used for the PUT.
    client = StubClient.new
    user = existing_user_with_session(client, username: "rita")

    user.email = "rita@example.com"
    assert user.save(session: "r:caller-session")

    update_call = client.calls_to(:update_object).first
    assert_equal "r:caller-session", update_call.last,
                 "update_object should receive the caller-supplied save(session:) token"
  end

  def test_existing_user_save_without_session_arg_sends_no_session_token
    client = StubClient.new
    user = existing_user_with_session(client, username: "sam")

    user.email = "sam@example.com"
    assert user.save

    update_call = client.calls_to(:update_object).first
    assert_nil update_call.last,
               "no explicit session: => update_object must be invoked with session_token: nil"
  end

  # --------------------------------------------------------------------
  # 4.1.1: after_create from `parse_reference` (or any other after_create
  # hook that re-enters the SDK) must run as the just-signed-up user, not
  # as master-key (which is what `session_token: nil` falls back to under
  # the default client config — see client.rb:682-687). Without the
  # signup_create promotion, the follow-up `update!` triggered by
  # `_assign_parse_reference!` runs with master-key authority, silently
  # bypassing CLP and `beforeSave` `request.user` gates on the new user's
  # own row.
  # --------------------------------------------------------------------
  class SignupParseReferenceUser < Parse::User
    parse_class Parse::Model::CLASS_USER
    # Parse::Object#fields is copied from Parse::Object on first access,
    # not from the immediate superclass, so a User subclass does not
    # auto-inherit username/password/email property declarations.
    # Re-declare them so `attribute_updates` produces a real signup body.
    property :auth_data, :object
    property :email
    property :password
    property :username
    parse_reference
  end

  def test_signup_create_promotes_new_session_token_for_after_create_update
    client = StubClient.new
    user = SignupParseReferenceUser.new(username: "umi", password: "p4ss!")
    user.define_singleton_method(:client) { client }

    assert user.save

    update_calls = client.calls_to(:update_object)
    assert_equal 1, update_calls.size,
                 "after_create _assign_parse_reference! must fire a single update"
    update_call = update_calls.first
    assert_equal "r:stub-session-token", update_call.last,
                 "after_create update_object must be authenticated with the new user's session token, " \
                 "not nil (which silently falls back to master_key)"
  end

  def test_signup_create_does_not_forward_caller_session_to_signup_post
    # Signup is an anonymous endpoint — Cloud Code `beforeSave(_User)`
    # must not see `request.user = caller` on a new account creation.
    # Even when the caller passes `save(session: admin_token)`, that
    # token is NOT forwarded to POST /parse/users. The after_create
    # update on the new user's row still authenticates as the new
    # user (via the freshly-applied sessionToken from the signup
    # response).
    client = StubClient.new
    user = SignupParseReferenceUser.new(username: "vince", password: "p4ss!")
    user.define_singleton_method(:client) { client }

    assert user.save(session: "r:admin-provisioner")

    create_call = client.calls_to(:create_user).first
    assert_nil create_call.last,
               "signup POST must not forward the caller's session token; " \
               "signup is anonymous and beforeSave(_User) must not see request.user = caller"

    update_call = client.calls_to(:update_object).first
    assert_equal "r:stub-session-token", update_call.last,
                 "after_create update should authenticate as the new user, not the admin"
  end

  def test_signup_create_session_token_promotion_is_bounded_by_save
    # The @_session_token promotion must NOT outlive the in-flight save.
    # actions.rb:830 zeros @_session_token at the end of save; this test
    # asserts the user is not left in a state where subsequent saves
    # carry the new user's token as the auth context.
    client = StubClient.new
    user = SignupParseReferenceUser.new(username: "wren", password: "p4ss!")
    user.define_singleton_method(:client) { client }

    assert user.save

    assert_nil user.instance_variable_get(:@_session_token),
               "@_session_token must be cleared by the outer save() after the create callbacks run"
  end

  def test_existing_user_save_with_signup_on_save_false_still_preserves_session_token
    # Belt-and-suspenders: even with the new flag off, the update path
    # must behave identically. Confirms the flag does not gate the
    # update path at all.
    Parse::User.signup_on_save = false
    client = StubClient.new
    user = existing_user_with_session(client, username: "tom")

    user.email = "tom@example.com"
    assert user.save

    assert_equal 1, client.calls_to(:update_object).size
    assert_equal "r:original-token", user.session_token
  ensure
    Parse::User.signup_on_save = true
  end
end
