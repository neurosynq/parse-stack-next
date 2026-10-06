# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Parse::Query resolves its table's model through parse_class, so schema
# lookups (pointer detection, pointer value conversion) work for Parse class
# names that are not valid Ruby constants, and for models whose parse_class
# differs from the Ruby class name. Before 5.8 the query layer used
# Parse::Model.const_get(@table), which raised for "contacts" and silently
# treated pointer fields as plain fields.
class QueryTableModelClassTest < Minitest::Test
  class LowercaseContact < Parse::Object
    parse_class "contacts"
    property :name, :string
    belongs_to :owner, as: :user
  end

  class RenamedLead < Parse::Object
    parse_class "SalesLead"
    belongs_to :owner, as: :user
  end

  def test_lowercase_parse_class_resolves_its_model
    q = Parse::Query.new("contacts")
    assert_equal LowercaseContact, q.send(:table_model_class)
    assert q.send(:field_is_pointer?, :owner), "owner is a pointer on the lowercase class"
    refute q.send(:field_is_pointer?, :name)
  end

  def test_parse_class_different_from_ruby_name_resolves
    q = Parse::Query.new("SalesLead")
    assert_equal RenamedLead, q.send(:table_model_class)
    assert q.send(:field_is_pointer?, :owner)
  end

  def test_pointer_values_convert_to_storage_form_for_lowercase_class
    q = Parse::Query.new("contacts")
    pointer = Parse::Pointer.new("_User", "u1")
    converted = q.send(:convert_pointer_value_with_schema, pointer, :owner, to_mongodb_format: true)
    assert_equal "_User$u1", converted
  end

  def test_unknown_table_resolves_to_nil_without_raising
    q = Parse::Query.new("no_such_table")
    assert_nil q.send(:table_model_class)
    refute q.send(:field_is_pointer?, :owner)
  end
end
