require_relative "../../../test_helper"

class ACLAccessHelperDocument < Parse::Object
  parse_class "ACLAccessHelperDocument"
  acl_policy :private

  property :owner, :object
end

class ACLAccessHelpersTest < Minitest::Test
  def setup
    Parse.setup(
      server_url: "http://localhost:1337/parse",
      application_id: "test",
      api_key: "test",
    ) unless Parse::Client.client?
    Parse::CLPScope.reset_cache!
    cache_clp({})

    @user = Parse::User.new
    @user.id = "u_alice"
    @other_user = Parse::User.new
    @other_user.id = "u_bob"
    @role = Parse::Role.new(name: "Admin")
    @role.id = "r_admin"
  end

  def teardown
    Parse::CLPScope.reset_cache!
  end

  def test_helpers_are_instance_predicates
    assert_respond_to @user, :can_read?
    assert_respond_to @user, :can_write?
    assert_respond_to @user, :can_delete?
    assert_respond_to @role, :can_read?
    assert_respond_to @role, :can_write?
    assert_respond_to @role, :can_delete?
  end

  def test_public_acl_honors_read_and_write_independently
    document = document_with(Parse::ACL.everyone(true, false))

    assert @user.can_read?(document)
    refute @user.can_write?(document)
    refute @user.can_delete?(document)
    assert @role.can_read?(document)
    refute @role.can_write?(document)
    refute @role.can_delete?(document)
  end

  def test_missing_acl_uses_parse_public_default
    document = document_with(nil)

    assert @user.can_read?(document)
    assert @user.can_write?(document)
    assert @user.can_delete?(document)
    assert @role.can_read?(document)
    assert @role.can_write?(document)
    assert @role.can_delete?(document)
  end

  def test_private_acl_and_invalid_targets_fail_closed
    document = document_with(Parse::ACL.private)

    refute @user.can_read?(document)
    refute @user.can_write?(document)
    refute @user.can_delete?(document)
    refute @role.can_read?(document)
    refute @role.can_write?(document)
    refute @role.can_delete?(document)
    refute @user.can_read?(Object.new)
    refute @role.can_write?(nil)
  end

  def test_user_direct_acl_grant
    acl = Parse::ACL.private
    acl.apply(@user.id, read: true, write: true)
    document = document_with(acl)

    assert @user.can_read?(document)
    assert @user.can_write?(document)
    assert @user.can_delete?(document)
    refute @other_user.can_read?(document)
    refute @other_user.can_write?(document)
    refute @other_user.can_delete?(document)
  end

  def test_user_and_role_records_are_acl_targets
    Parse::CLPScope.__cache_put(Parse::Model::CLASS_ROLE, clp: {})
    Parse::CLPScope.__cache_put(Parse::Model::CLASS_USER, clp: {})

    target_role = Parse::Role.new(name: "Target")
    target_role.id = "r_target"
    target_role_acl = Parse::ACL.private
    target_role_acl.apply(@user.id, read: true, write: false)
    target_role.acl = target_role_acl

    assert @user.can_read?(target_role)
    refute @user.can_write?(target_role)
    refute @user.can_delete?(target_role)

    target_user_acl = Parse::ACL.private
    target_user_acl.apply_role(@role.name, read: true, write: true)
    @other_user.acl = target_user_acl

    assert @role.can_read?(@other_user)
    assert @role.can_write?(@other_user)
    assert @role.can_delete?(@other_user)
  end

  def test_clp_denial_overrides_public_acl
    cache_clp(
      "get" => {},
      "update" => { "*" => true },
      "delete" => {},
    )
    document = document_with(Parse::ACL.everyone)

    refute @user.can_read?(document)
    assert @user.can_write?(document)
    refute @user.can_delete?(document)
    refute @role.can_read?(document)
    assert @role.can_write?(document)
    refute @role.can_delete?(document)
  end

  def test_user_inherits_acl_and_clp_grants_from_roles
    cache_clp(
      "get" => { "role:Moderator" => true },
      "update" => { "role:Moderator" => true },
      "delete" => { "role:Moderator" => true },
    )
    acl = Parse::ACL.private
    acl.apply_role("Moderator", read: true, write: true)
    document = document_with(acl)

    Parse::Role.stub(:all_for_user, Set["Member", "Moderator"]) do
      assert @user.can_read?(document)
      assert @user.can_write?(document)
      assert @user.can_delete?(document)
    end
  end

  def test_direct_role_grants_do_not_require_parent_lookup
    cache_clp(
      "get" => { "role:Admin" => true },
      "update" => { "role:Admin" => true },
      "delete" => { "role:Admin" => true },
    )
    acl = Parse::ACL.private
    acl.apply_role("Admin", read: true, write: true)
    document = document_with(acl)
    unexpected_lookup = ->(**) { raise "parent lookup should not run" }

    @role.stub(:all_parent_role_names, unexpected_lookup) do
      assert @role.can_read?(document)
      assert @role.can_write?(document)
      assert @role.can_delete?(document)
    end
  end

  def test_role_inherits_acl_and_clp_grants_from_parent_roles
    cache_clp(
      "get" => { "role:Moderator" => true },
      "update" => { "role:Moderator" => true },
      "delete" => { "role:Moderator" => true },
    )
    acl = Parse::ACL.private
    acl.apply_role("Moderator", read: true, write: true)
    document = document_with(acl)

    @role.stub(:all_parent_role_names, Set["Admin", "Moderator"]) do
      assert @role.can_read?(document)
      assert @role.can_write?(document)
      assert @role.can_delete?(document)
    end
  end

  def test_role_members_satisfy_authenticated_clp
    cache_clp(
      "get" => { "requiresAuthentication" => true },
      "update" => { "requiresAuthentication" => true },
      "delete" => { "requiresAuthentication" => true },
    )
    acl = Parse::ACL.private
    acl.apply_role("Admin", read: true, write: true)
    document = document_with(acl)

    assert @role.can_read?(document)
    assert @role.can_write?(document)
    assert @role.can_delete?(document)
  end

  def test_role_lookup_failure_denies_inherited_grants
    cache_clp("get" => { "role:Moderator" => true })
    acl = Parse::ACL.private
    acl.apply_role("Moderator", read: true, write: false)
    document = document_with(acl)
    failed_lookup = ->(*_args, **_kwargs) { raise StandardError, "offline" }

    Parse::Role.stub(:all_for_user, failed_lookup) do
      refute @user.can_read?(document)
    end
    @role.stub(:all_parent_role_names, failed_lookup) do
      refute @role.can_read?(document)
    end
  end

  def test_user_field_clp_is_checked_against_the_object
    cache_clp(
      "get" => { "requiresAuthentication" => true },
      "update" => { "requiresAuthentication" => true },
      "delete" => { "requiresAuthentication" => true },
      "readUserFields" => ["owner"],
      "writeUserFields" => ["owner"],
    )
    owner_pointer = {
      "__type" => "Pointer",
      "className" => Parse::Model::CLASS_USER,
      "objectId" => @user.id,
    }
    document = document_with(Parse::ACL.everyone, owner: owner_pointer)

    assert @user.can_read?(document)
    assert @user.can_write?(document)
    assert @user.can_delete?(document)
    refute @other_user.can_read?(document)
    refute @other_user.can_write?(document)
    refute @other_user.can_delete?(document)
    refute @role.can_read?(document), "a role alone cannot prove a user-field match"
    refute @role.can_write?(document), "a role alone cannot prove a user-field match"
    refute @role.can_delete?(document), "a role alone cannot prove a user-field match"
  end

  def test_user_fields_for_maps_read_and_write_operations
    cache_clp(
      "readUserFields" => ["owner"],
      "writeUserFields" => ["editor"],
    )

    assert_equal ["owner"], Parse::CLPScope.user_fields_for(parse_class, :get)
    assert_equal ["owner"], Parse::CLPScope.user_fields_for(parse_class, :find)
    assert_equal ["editor"], Parse::CLPScope.user_fields_for(parse_class, :update)
    assert_nil Parse::CLPScope.user_fields_for(parse_class, :create)
  end

  private

  def parse_class
    ACLAccessHelperDocument.parse_class
  end

  def cache_clp(clp)
    Parse::CLPScope.__cache_put(parse_class, clp: clp)
  end

  def document_with(acl, owner: nil)
    document = ACLAccessHelperDocument.new
    if acl.nil?
      # The ACL property typecasts an assigned nil into `Parse::ACL.private`.
      # Set the hydrated value directly to model a legacy server row whose ACL
      # field is genuinely absent (Parse Server treats that as public).
      document.instance_variable_set(:@acl, nil)
    else
      document.acl = acl
    end
    document.owner = owner unless owner.nil?
    document
  end
end
