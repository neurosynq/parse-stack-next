require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"
require "securerandom"

# CLP enforcement, protectedFields (set-but-not-read), and anonymous
# (no session-token) behaviors, all observed from the SDK-as-client
# side. The shared theme: when the client has no master key, the server
# must enforce what the schema declares — not whatever the client
# requests.
#
# Implementation note on assertions: Parse Server returns CLP/ACL
# rejections as JSON bodies with `code: 101` and an HTTP 200/4xx that
# the SDK middleware does NOT translate into a raise. So we assert on
# `response.success?` and `response.error` rather than on `assert_raises`.
class ClientClpProbe < Parse::Object
  parse_class "ClientClpProbe"
  property :public_field, :string
  property :secret_field, :string
end

class ClientRestClpAnonymousIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
    @user, @password = seed_client_user("clp")
    install_class_with_clp!
  end

  # The fixture class is created up-front under master key with:
  #   * find/get/count permitted to authenticated users
  #   * create permitted to authenticated users
  #   * update/delete restricted by `requiresAuthentication` (per-row
  #     authorization is then enforced by ACL on the row itself)
  #   * protectedFields: secret_field readable only by master key
  #
  # This is the canonical "client can write a value but cannot read it
  # back" shape — for instance, a password-hash sidecar or a server-
  # assigned audit field.
  def install_class_with_clp!
    with_master_key do
      # NB: Parse Server stores Ruby `property :public_field` as
      # `publicField` (the SDK's snake-to-camel convention). The schema
      # field names AND the `protectedFields` field list must use the
      # camelCase form or `Parse::Query.where(public_field: ...)` will
      # query a column that doesn't exist.
      schema = {
        "className" => "ClientClpProbe",
        "fields" => {
          "publicField" => { "type" => "String" },
          "secretField" => { "type" => "String" },
        },
        "classLevelPermissions" => {
          "find"   => { "requiresAuthentication" => true },
          "get"    => { "requiresAuthentication" => true },
          "count"  => { "requiresAuthentication" => true },
          "create" => { "requiresAuthentication" => true },
          "update" => { "requiresAuthentication" => true },
          "delete" => { "requiresAuthentication" => true },
          "addField" => {},
          "protectedFields" => {
            # Strip secretField for everyone except master key
            # (represented by the absence of a permitting key).
            "*" => ["secretField"],
          },
        },
      }

      # Try update first; if the class doesn't exist yet, create.
      response = Parse.client.update_schema("ClientClpProbe", schema)
      Parse.client.create_schema("ClientClpProbe", schema) unless response.success?
    end
  end

  # --------------------------------------------------------------------
  # Anonymous (no session-token) reads must be rejected because
  # find/get require authentication.
  # --------------------------------------------------------------------
  def test_anonymous_read_blocked_by_requires_auth_clp
    as_client do
      response = Parse.client.find_objects("ClientClpProbe", {}, use_master_key: false)
      refute response.success?, "anonymous find on requiresAuthentication class must fail"
      assert_match(/auth|permission|forbidden|not allowed/i, response.error.to_s,
                   "rejection must be a CLP/auth error, got: #{response.error.inspect}")
    end
  end

  # --------------------------------------------------------------------
  # Anonymous write must be rejected for the same reason.
  # --------------------------------------------------------------------
  def test_anonymous_create_blocked_by_requires_auth_clp
    as_client do
      response = Parse.client.create_object(
        "ClientClpProbe", { "publicField" => "anon" }, use_master_key: false,
      )
      refute response.success?, "anonymous create on requiresAuthentication class must fail"
      assert_match(/auth|permission|forbidden|not allowed/i, response.error.to_s,
                   "rejection must be a CLP/auth error, got: #{response.error.inspect}")
    end
  end

  # --------------------------------------------------------------------
  # Authenticated client CAN write secret_field (POST body accepts it)
  # but the readback from the SAME session must NOT include it. This is
  # the "set but cannot read" protected-fields semantic.
  # --------------------------------------------------------------------
  def test_client_can_set_protected_field_but_not_read_it
    as_client do
      me = Parse::User.login(@user.username, @password)

      created = Parse.client.create_object(
        "ClientClpProbe",
        { "publicField" => "visible", "secretField" => "hidden-by-clp" },
        session_token: me.session_token, use_master_key: false,
      )
      assert created.success?, "client-authed create should succeed (#{created.error.inspect})"
      id = created.result["objectId"]
      refute_nil id

      # Read back as the same client. protectedFields["*"] should strip
      # secret_field.
      readback = Parse.client.fetch_object(
        "ClientClpProbe", id,
        session_token: me.session_token, use_master_key: false,
      )
      assert readback.success?, "authed get must succeed (#{readback.error.inspect})"
      assert_equal "visible", readback.result["publicField"]
      refute readback.result.key?("secretField"),
             "protectedFields must strip secret_field from non-master readback, got: #{readback.result.inspect}"

      # Same field is visible via master key — confirms the value was
      # actually persisted (not silently dropped on write).
      with_master_key do
        admin = Parse.client.fetch_object("ClientClpProbe", id)
        assert_equal "hidden-by-clp", admin.result["secretField"],
                     "master-key readback proves the value was persisted; CLP only masked the client read"
      end
    end
  end

  # --------------------------------------------------------------------
  # Query results from a Parse::Query must also have protected fields
  # stripped — not just direct fetch_object.
  # --------------------------------------------------------------------
  def test_protected_field_stripped_from_query_results
    as_client do
      me = Parse::User.login(@user.username, @password)
      created = Parse.client.create_object(
        "ClientClpProbe",
        { "publicField" => "q-visible", "secretField" => "q-hidden" },
        session_token: me.session_token, use_master_key: false,
      )
      assert created.success?, "client-authed create should succeed (#{created.error.inspect})"

      q = Parse::Query.new("ClientClpProbe")
      q.session_token = me.session_token
      q.where(public_field: "q-visible")

      results = q.results
      refute_empty results, "client query should return its own row"
      row = results.first
      attrs = row.respond_to?(:attributes) ? row.attributes : row
      refute attrs.key?("secretField") || attrs.key?(:secret_field),
             "Parse::Query result must not surface protected secret_field"
    end
  end

  # --------------------------------------------------------------------
  # An update from a different authenticated user must be rejected when
  # the row's ACL doesn't grant them write — verifying that "create
  # requires auth" does NOT degrade into "any authed user can write any
  # row." This is the boundary between CLP and ACL.
  # --------------------------------------------------------------------
  def test_other_authed_user_cannot_update_acl_private_row
    other_user, other_password = seed_client_user("clp_other")

    as_client do
      me = Parse::User.login(@user.username, @password)
      created = Parse.client.create_object(
        "ClientClpProbe",
        {
          "publicField" => "owned",
          # ACL: only me can read/write.
          "ACL" => { me.id => { "read" => true, "write" => true } },
        },
        session_token: me.session_token, use_master_key: false,
      )
      assert created.success?, "owner create should succeed (#{created.error.inspect})"
      id = created.result["objectId"]

      other = Parse::User.login(other_user.username, other_password)
      response = Parse.client.update_object(
        "ClientClpProbe", id,
        { "publicField" => "tampered" },
        session_token: other.session_token, use_master_key: false,
      )
      refute response.success?, "other user must not be able to update an ACL-private row"
      assert_match(/permission|forbidden|acl|not allowed|object not found/i, response.error.to_s,
                   "rejection must be a permission/not-found error, got: #{response.error.inspect}")
    end
  end
end
