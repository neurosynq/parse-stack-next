require_relative "../../test_helper"
require "minitest/autorun"

class DescribeAccessFullSurface < Parse::Object
  parse_class "DescribeAccessFullSurface"

  property :title, :string
  property :owner, :string
  property :slug, :string
  property :secret, :string

  guard :owner, :master_only
  guard :slug, :immutable

  protect_fields "*", [:secret]

  set_class_access(
    find:   :public,
    get:    :public,
    create: :authenticated,
    update: "Admin",
    delete: :master,
  )

  parse_reference   # also installs :set_once + protect_fields("*", [:parse_reference])

  def autofetch!(*); nil; end
end

class DescribeAccessBareClass < Parse::Object
  parse_class "DescribeAccessBareClass"
  property :name, :string
  def autofetch!(*); nil; end
end

class DescribeAccessMultiword < Parse::Object
  parse_class "DescribeAccessMultiword"
  property :full_name, :string
  property :internal_note, :string
  guard :internal_note, :master_only
  protect_fields "*", [:internal_note]
  def autofetch!(*); nil; end
end

class DescribeAccessTest < Minitest::Test
  def setup
    @access = DescribeAccessFullSurface.describe_access
  end

  def test_returns_a_hash_with_expected_keys
    assert_kind_of Hash, @access
    %i[operations read_user_fields write_user_fields fields].each do |key|
      assert @access.key?(key), "describe_access must include :#{key}"
    end
  end

  def test_operations_reflect_set_class_access
    ops = @access[:operations]
    assert_equal({ "*" => true }, ops[:find], ":public => *=true")
    assert_equal({ "*" => true }, ops[:get])
    assert_equal({ "requiresAuthentication" => true }, ops[:create])
    assert_equal({ "role:Admin" => true }, ops[:update])
    assert_equal({}, ops[:delete], ":master => empty perm")
  end

  def test_unguarded_fields_marked_open
    title = @access[:fields][:title]
    assert_equal :open, title[:write]
    assert_equal :open, title[:read]
    assert_equal :string, title[:type]
  end

  def test_field_guards_surface_in_write_column
    assert_equal :master_only, @access[:fields][:owner][:write]
    assert_equal :immutable,   @access[:fields][:slug][:write]
  end

  def test_protected_fields_surface_in_read_column_as_hidden_from
    secret = @access[:fields][:secret][:read]
    assert_kind_of Hash, secret, "read-side protection serializes as a hash"
    assert_includes secret[:hidden_from], "*"
  end

  def test_parse_reference_field_has_both_set_once_and_read_hiding
    pr = @access[:fields][:parse_reference]
    refute_nil pr, "parse_reference field must appear"
    assert_equal :set_once, pr[:write], ":set_once guard auto-installed"
    assert_kind_of Hash, pr[:read]
    assert_includes pr[:read][:hidden_from], "*",
                    "parse_reference is auto-added to protectedFields('*')"
  end

  def test_bare_class_has_no_guards_no_protections
    access = DescribeAccessBareClass.describe_access
    assert_equal :open, access[:fields][:name][:write]
    assert_equal :open, access[:fields][:name][:read]
  end

  def test_no_internal_or_base_fields_leak
    %i[id created_at updated_at acl].each do |internal|
      refute @access[:fields].key?(internal),
             "describe_access must not list internal/base field :#{internal}"
    end
  end

  def test_multiword_fields_only_appear_under_local_name
    # Regression: previously iterating `fields.each` yielded both the
    # local symbol (:full_name) AND the remote symbol (:fullName) for
    # multi-word properties, so the same property appeared twice in
    # the output.
    access = DescribeAccessMultiword.describe_access
    assert access[:fields].key?(:full_name)
    refute access[:fields].key?(:fullName), "remote-name duplicate must not appear"
    assert access[:fields].key?(:internal_note)
    refute access[:fields].key?(:internalNote)
  end

  def test_protected_fields_uses_remote_name_internally_but_matches_local
    # protect_fields converts to camelCase internally. describe_access
    # must still match the field by its local name and surface the
    # protection on the local symbol entry.
    access = DescribeAccessMultiword.describe_access
    read = access[:fields][:internal_note][:read]
    assert_kind_of Hash, read
    assert_includes read[:hidden_from], "*"
  end

  def test_operations_hash_is_safe_to_mutate
    # Reviewer flagged shallow dup. Mutating the returned operations
    # hash must not bleed into the class's CLP state.
    @access[:operations][:find]["*"] = false
    fresh = DescribeAccessFullSurface.describe_access
    assert_equal true, fresh[:operations][:find]["*"],
                 "describe_access must return an independent copy of operations"
  end
end
