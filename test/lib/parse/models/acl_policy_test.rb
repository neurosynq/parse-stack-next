require_relative "../../../test_helper"

# Test models exercising every cell of the acl_policy matrix.
# Suppress the permissive-default warning so test output stays clean;
# the warning emission itself is exercised in a dedicated test.
Parse::Object.suppress_permissive_acl_warning = true

class AclPolicyPublicModel < Parse::Object
  property :title, :string
  acl_policy :public
end

class AclPolicyPrivateModel < Parse::Object
  property :title, :string
  acl_policy :private
end

class AclPolicyOwnerElsePublicModel < Parse::Object
  property :title, :string
  belongs_to :user, as: :user
  acl_policy :owner_else_public, owner: :user
end

class AclPolicyOwnerElsePrivateModel < Parse::Object
  property :title, :string
  belongs_to :author, as: :user
  acl_policy :owner_else_private, owner: :author
end

class AclPolicyChildModel < AclPolicyOwnerElsePrivateModel
  # inherits :owner_else_private, owner: :author from parent
end

class TestAclPolicy < Minitest::Test
  PUBLIC_RW = { "*" => { "read" => true, "write" => true } }.freeze

  def make_user(id = "u123")
    Parse::User.new(objectId: id)
  end

  def resolve(obj)
    obj.send(:_resolve_default_acl)
    obj
  end

  # ---- :public ----

  def test_public_policy_resolves_to_public_rw
    obj = AclPolicyPublicModel.new(title: "x")
    assert_equal PUBLIC_RW, resolve(obj).acl.as_json
  end

  def test_public_policy_ignores_owner
    obj = AclPolicyPublicModel.new(title: "x", as: make_user)
    assert_equal PUBLIC_RW, resolve(obj).acl.as_json
  end

  # ---- :private ----

  def test_private_policy_resolves_to_master_key_only
    obj = AclPolicyPrivateModel.new(title: "x")
    assert_equal({}, resolve(obj).acl.as_json)
  end

  def test_private_policy_ignores_owner
    obj = AclPolicyPrivateModel.new(title: "x", as: make_user)
    assert_equal({}, resolve(obj).acl.as_json)
  end

  # ---- :owner_else_public ----

  def test_owner_else_public_falls_back_to_public_when_no_owner
    obj = AclPolicyOwnerElsePublicModel.new(title: "x")
    assert_equal PUBLIC_RW, resolve(obj).acl.as_json
  end

  def test_owner_else_public_uses_as_kwarg_owner
    user = make_user("alice")
    obj = AclPolicyOwnerElsePublicModel.new(title: "x", as: user)
    assert_equal({ "alice" => { "read" => true, "write" => true } }, resolve(obj).acl.as_json)
  end

  def test_owner_else_public_uses_owner_field
    user = make_user("bob")
    obj = AclPolicyOwnerElsePublicModel.new(title: "x", user: user)
    assert_equal({ "bob" => { "read" => true, "write" => true } }, resolve(obj).acl.as_json)
  end

  def test_owner_else_public_as_kwarg_wins_over_field
    field_user = make_user("field")
    explicit_user = make_user("explicit")
    obj = AclPolicyOwnerElsePublicModel.new(title: "x", user: field_user, as: explicit_user)
    assert_equal({ "explicit" => { "read" => true, "write" => true } }, resolve(obj).acl.as_json)
  end

  # ---- :owner_else_private ----

  def test_owner_else_private_falls_back_to_master_key_only
    obj = AclPolicyOwnerElsePrivateModel.new(title: "x")
    assert_equal({}, resolve(obj).acl.as_json)
  end

  def test_owner_else_private_uses_owner_field
    user = make_user("carol")
    obj = AclPolicyOwnerElsePrivateModel.new(title: "x", author: user)
    assert_equal({ "carol" => { "read" => true, "write" => true } }, resolve(obj).acl.as_json)
  end

  def test_owner_else_private_uses_as_kwarg
    user = make_user("dave")
    obj = AclPolicyOwnerElsePrivateModel.new(title: "x", as: user)
    assert_equal({ "dave" => { "read" => true, "write" => true } }, resolve(obj).acl.as_json)
  end

  # ---- caller-wins ----

  def test_caller_set_acl_is_never_overwritten_by_resolver
    user = make_user("would-be-owner")
    obj = AclPolicyOwnerElsePrivateModel.new(title: "x", author: user)
    custom = Parse::ACL.new
    custom.apply("custom-user", true, false)
    obj.acl = custom.as_json
    resolve(obj)
    assert_equal({ "custom-user" => { "read" => true } }, obj.acl.as_json)
  end

  def test_acl_supplied_in_opts_is_treated_as_caller_set
    obj = AclPolicyOwnerElsePrivateModel.new(title: "x", acl: { "supplied" => { "read" => true } })
    resolve(obj)
    assert_equal({ "supplied" => { "read" => true } }, obj.acl.as_json)
  end

  # ---- inheritance ----

  def test_subclass_inherits_parent_policy_and_owner_field
    assert_equal :owner_else_private, AclPolicyChildModel.acl_policy_setting
    assert_equal :author, AclPolicyChildModel.acl_owner_field
  end

  def test_inherited_policy_resolves_correctly
    user = make_user("heir")
    obj = AclPolicyChildModel.new(title: "x", author: user)
    assert_equal({ "heir" => { "read" => true, "write" => true } }, resolve(obj).acl.as_json)
  end

  # ---- `as:` plumbing ----

  def test_as_kwarg_is_not_persisted_as_property
    obj = AclPolicyOwnerElsePrivateModel.new(title: "x", as: make_user)
    refute obj.respond_to?(:as), "obj should not expose `as` as a property"
    refute_includes obj.attributes.keys.map(&:to_s), "as"
  end

  def test_as_works_with_raw_object_id_string
    obj = AclPolicyOwnerElsePrivateModel.new(title: "x", as: "raw-id")
    assert_equal({ "raw-id" => { "read" => true, "write" => true } }, resolve(obj).acl.as_json)
  end

  # ---- invalid input ----

  def test_invalid_policy_raises
    assert_raises(ArgumentError) do
      Class.new(Parse::Object) do
        def self.name; "InvalidPolicyClass"; end
        acl_policy :not_a_real_policy
      end
    end
  end

  # ---- backward compat with set_default_acl (additive form) ----

  class LegacySetDefaultAclModel < Parse::Object
    set_default_acl :public, read: true, write: false
    set_default_acl "Admin", role: true, read: true, write: true
  end

  def test_set_default_acl_still_works_for_legacy_callers
    obj = LegacySetDefaultAclModel.new
    json = obj.acl.as_json
    assert_equal({ "read" => true }, json["*"],
                 "public read should be set by legacy set_default_acl")
    assert_equal({ "read" => true, "write" => true }, json["role:Admin"],
                 "role perms should be set by legacy set_default_acl")
  end

  # ---- owner type-gating ----

  def test_owner_pointer_to_user_class_resolves
    pointer = Parse::Pointer.new("_User", "ptr-user")
    obj = AclPolicyOwnerElsePrivateModel.new(title: "x", as: pointer)
    assert_equal({ "ptr-user" => { "read" => true, "write" => true } }, resolve(obj).acl.as_json)
  end

  def test_pointer_to_non_user_class_falls_through
    # A pointer to some other class (e.g. Team) must NOT be granted ACL access
    # as if it were a user; that would silently grant a non-user objectId
    # write access if the User collection happens to contain a record with
    # the same id.
    team_ptr = Parse::Pointer.new("Team", "team-id")
    obj = AclPolicyOwnerElsePrivateModel.new(title: "x", as: team_ptr)
    assert_equal({}, resolve(obj).acl.as_json, "non-User pointer should be rejected, falling through to private")
  end

  def test_arbitrary_object_with_id_is_rejected
    # Previously any object responding to #id was accepted. After tightening,
    # only Parse::User, Parse::Pointer to _User, or raw String ids work.
    fake = Struct.new(:id).new("fake-id")
    obj = AclPolicyOwnerElsePrivateModel.new(title: "x", as: fake)
    assert_equal({}, resolve(obj).acl.as_json, "arbitrary object with .id should be rejected")
  end

  # ---- mixing set_default_acl + acl_policy raises ----

  def test_set_default_acl_after_acl_policy_raises
    assert_raises(ArgumentError) do
      Class.new(Parse::Object) do
        def self.name; "MixedConfig1"; end
        acl_policy :owner_else_private, owner: :user
        set_default_acl :public, read: true, write: false
      end
    end
  end

  def test_acl_policy_after_set_default_acl_raises
    assert_raises(ArgumentError) do
      Class.new(Parse::Object) do
        def self.name; "MixedConfig2"; end
        set_default_acl :public, read: true, write: false
        acl_policy :owner_else_private, owner: :user
      end
    end
  end

  # ---- built-in classes are exempt from ACL stamping ----

  def test_parse_user_acl_is_not_stamped_by_sdk
    # Critical: with :owner_else_private as the gem-wide default, stamping
    # an empty ACL on Parse::User would lock the new user out of editing
    # their own profile without the master key. The SDK must leave acl nil
    # so Parse Server applies its standard "self R/W + public read" default.
    user = Parse::User.new(username: "test", password: "secret", email: "t@example.com")
    assert_nil user.acl, "Parse::User instances must have nil acl so Parse Server's per-class default applies"
  end

  def test_parse_installation_acl_is_not_stamped
    install = Parse::Installation.new(device_type: "ios")
    assert_nil install.acl, "Parse::Installation must have nil acl so Parse Server's default applies"
  end

  def test_resolver_does_not_overwrite_user_acl
    user = Parse::User.new(username: "test", password: "secret")
    user.send(:_resolve_default_acl)
    assert_nil user.acl, "resolver must not stamp ACL onto built-in classes"
  end

  def test_user_subclass_with_acl_policy_still_works
    # A user-defined subclass of Parse::User (not the built-in itself)
    # should still respect any acl_policy declared on it. Subclasses are
    # not in BUILTIN_PARSE_CLASS_NAMES, so the resolver runs normally.
    klass = Class.new(Parse::User) do
      def self.name; "AppUser"; end
      acl_policy :public
    end
    obj = klass.new(username: "x", password: "y")
    # Even though Parse::User is built-in, AppUser is not — so init stamps
    # the default ACL per the explicit :public policy.
    refute_nil obj.acl, "user-defined Parse::User subclass should still get ACL stamped per its acl_policy"
    obj.send(:_resolve_default_acl)
    assert_equal PUBLIC_RW, obj.acl.as_json
  end

  # ---- gem-wide default is :owner_else_private ----

  def test_gem_wide_default_is_owner_else_private
    assert_equal :owner_else_private, Parse::Object.acl_policy_setting,
                 "gem-wide default should be the secure :owner_else_private"
    bare_class = Class.new(Parse::Object) { def self.name; "BareClass"; end }
    assert_equal :owner_else_private, bare_class.acl_policy_setting,
                 "subclasses without explicit policy inherit gem-wide default"
  end

  # ---- owner: :self for self-referential User ACL ----

  class SelfOwnedUser < Parse::User
    def self.parse_class; "_User"; end
    acl_policy :owner_else_private, owner: :self
  end

  def test_self_owner_pregenerates_id_and_grants_self_rw
    user = SelfOwnedUser.new(username: "u", password: "p")
    assert_nil user.id, "id should not be set yet"
    resolve(user)
    refute_nil user.id, "resolver should pre-generate objectId for owner: :self"
    assert_match(/\A[A-Za-z0-9]{10}\z/, user.id, "generated id should match Parse format")
    assert_equal({ user.id => { "read" => true, "write" => true } }, user.acl.as_json,
                 "ACL should grant self R/W only")
  end

  def test_self_owner_preserves_existing_id
    user = SelfOwnedUser.new(username: "u", password: "p")
    user.instance_variable_set(:@id, "ExistingId")
    resolve(user)
    assert_equal "ExistingId", user.id, "should not overwrite an already-assigned objectId"
    assert_equal({ "ExistingId" => { "read" => true, "write" => true } }, user.acl.as_json)
  end

  def test_self_owner_rejected_on_non_user_class
    err = assert_raises(ArgumentError) do
      Class.new(Parse::Object) do
        def self.name; "NotAUser"; end
        acl_policy :owner_else_private, owner: :self
      end
    end
    assert_match(/Parse::User and its subclasses/, err.message)
  end

  # ---- signup body safe-pattern whitelist ----

  def test_signup_body_safe_pattern_accepts_self_only_acl
    body = {
      objectId: "AbCdEf1234",
      ACL: { "AbCdEf1234" => { "read" => true, "write" => true } },
      username: "u", password: "p",
    }
    assert Parse::User.signup_body_self_only_acl_safe?(body)
  end

  def test_signup_body_rejects_extra_acl_keys
    body = {
      objectId: "AbCdEf1234",
      ACL: {
        "AbCdEf1234" => { "read" => true, "write" => true },
        "OtherUser1" => { "read" => true, "write" => true },
      },
    }
    refute Parse::User.signup_body_self_only_acl_safe?(body),
           "ACL with more than the self entry must not be allowed through"
  end

  def test_signup_body_rejects_public_grant
    body = {
      objectId: "AbCdEf1234",
      ACL: { "*" => { "read" => true, "write" => true } },
    }
    refute Parse::User.signup_body_self_only_acl_safe?(body)
  end

  def test_signup_body_rejects_role_grant
    body = {
      objectId: "AbCdEf1234",
      ACL: { "role:Admin" => { "read" => true, "write" => true } },
    }
    refute Parse::User.signup_body_self_only_acl_safe?(body)
  end

  def test_signup_body_rejects_mismatched_objectId_acl_key
    body = {
      objectId: "AbCdEf1234",
      ACL: { "DifferentId" => { "read" => true, "write" => true } },
    }
    refute Parse::User.signup_body_self_only_acl_safe?(body),
           "ACL key must equal the body's objectId"
  end

  def test_signup_body_rejects_read_only_acl
    body = {
      objectId: "AbCdEf1234",
      ACL: { "AbCdEf1234" => { "read" => true } },
    }
    refute Parse::User.signup_body_self_only_acl_safe?(body),
           "ACL must grant both read AND write (no half-permissions)"
  end

  def test_signup_body_rejects_non_parse_id_format
    body = {
      objectId: "not-an-id",
      ACL: { "not-an-id" => { "read" => true, "write" => true } },
    }
    refute Parse::User.signup_body_self_only_acl_safe?(body),
           "objectId must match the 10-char Parse format"
  end

  def test_signup_body_rejects_missing_acl
    body = { objectId: "AbCdEf1234" }
    refute Parse::User.signup_body_self_only_acl_safe?(body)
  end

  def test_signup_body_rejects_missing_objectId
    body = { ACL: { "AbCdEf1234" => { "read" => true, "write" => true } } }
    refute Parse::User.signup_body_self_only_acl_safe?(body)
  end

  # ---- one-time per-class warning ----

  def test_permissive_warning_fires_once_per_class
    klass = Class.new(Parse::Object) do
      def self.name; "WarningTestClass"; end
      acl_policy :owner_else_public, owner: :user
    end
    # Re-enable warning emission just for this test
    Parse::Object.suppress_permissive_acl_warning = false
    begin
      _out, err = capture_io do
        2.times { klass.new(title: "x") }
      end
      assert_match(/permissive default ACL policy/, err)
      assert_equal 1, err.scan(/permissive default ACL policy/).length,
                   "warning should fire exactly once per class"
    ensure
      Parse::Object.suppress_permissive_acl_warning = true
    end
  end
end
