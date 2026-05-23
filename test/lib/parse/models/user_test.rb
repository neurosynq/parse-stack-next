require_relative "../../../test_helper"

class TestUser < Minitest::Test
  CORE_FIELDS = Parse::Object.fields.merge({
    auth_data: :object,
    authData: :object,
    email: :string,
    email_verified: :boolean,
    emailVerified: :boolean,
    password: :string,
    username: :string,
  })

  def test_properties
    assert Parse::User < Parse::Object
    assert_equal CORE_FIELDS, Parse::User.fields
    assert_empty Parse::User.references
    assert_empty Parse::User.relations
  end

  def test_password_reset
    assert_equal Parse::User.request_password_reset(""), false
    assert_equal Parse::User.request_password_reset("   "), false
  end

  def test_email_verified_is_master_only_guarded
    # Defense-in-depth: client writes to `email_verified` (from any
    # platform) are silently reverted at the `_User.beforeSave` webhook
    # boundary. Master-key callers bypass the guard so the server-side
    # email verification callback can still flip the flag.
    assert_equal :master_only, Parse::User.field_guards[:email_verified],
                 "Parse::User should declare guard :email_verified, :master_only"
  end
end
