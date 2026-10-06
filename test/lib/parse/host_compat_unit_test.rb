require_relative "../../test_helper"

# Host-application compatibility: core-extension hygiene, pluralized alias
# scoping, schema migration of SDK-only types, the model builder's handling
# of server columns that clash with Ruby methods, and Parse::User naming.

class HostCompatPost < Parse::Object
  parse_class "HostCompatPost"
  property :title, :string
end

module HostCompatBlog
  class Entry < Parse::Object
    parse_class "HostCompatEntry"
    property :headline, :string
  end
end

module HostCompatUnrelated; end

class HostCompatAuthor < Parse::Object
  parse_class "HostCompatAuthor"
end

class HostCompatBook < Parse::Object
  parse_class "HostCompatBook"
  property :title
  belongs_to :host_compat_author
  has_many :fans, through: :relation, as: :user
  property :embedding, :vector, dimensions: 3
  property :tz, :timezone
  property :phone, :phone
  property :mail, :email
end

class HostCompatUnitTest < Minitest::Test
  # --- core extensions -----------------------------------------------------

  def test_symbol_size_is_rubys_own
    assert_equal 3, :abc.size
    assert_equal %i[a bb ccc], %i[ccc a bb].sort_by(&:size)
  end

  def test_symbol_does_not_respond_to_id
    refute :draft.respond_to?(:id), "Symbol#id makes ActiveRecord treat a symbol as a record"
  end

  def test_renamed_operators_build_the_same_constraints
    assert_instance_of Parse::Constraint::ArraySizeConstraint, :tags.array_size(2)
    assert_instance_of Parse::Constraint::ObjectIdConstraint, :author.pointer_id("abc")
    q = Parse::Query.new("Song")
    q.where(:tags.array_size => 2)
    assert_equal Parse::Query.new("Song").where(Parse::Operation.new(:tags, :size) => 2).compile_where,
                 q.compile_where
  end

  def test_query_dsl_is_in_an_included_module
    assert_includes Symbol.ancestors, Parse::Operation::SymbolMethods
    assert_includes Symbol.ancestors, Parse::Order::SymbolMethods
    assert_equal Parse::Operation::SymbolMethods, Symbol.instance_method(:gt).owner
    assert_equal Symbol, Symbol.instance_method(:size).owner
  end

  # --- pluralized aliases --------------------------------------------------

  def teardown
    Object.send(:remove_const, :HostCompatPosts) if Object.const_defined?(:HostCompatPosts, false)
    HostCompatBlog.send(:remove_const, :Entries) if HostCompatBlog.const_defined?(:Entries, false)
  end

  def test_unrelated_module_never_receives_an_alias_constant
    klass = HostCompatUnrelated.const_get(:HostCompatPosts)
    assert klass.equal?(HostCompatPost)
    refute HostCompatUnrelated.const_defined?(:HostCompatPosts, false)
    assert Object.const_defined?(:HostCompatPosts, false)
  end

  def test_lexical_reference_installs_alias_at_home_namespace
    assert HostCompatPosts.equal?(HostCompatPost)
    refute self.class.const_defined?(:HostCompatPosts, false)
  end

  def test_namespaced_alias_stays_in_its_namespace
    assert HostCompatBlog::Entries.equal?(HostCompatBlog::Entry)
    refute Object.const_defined?(:Entries, false)
  end

  def test_frozen_module_lookup_does_not_raise_frozen_error
    frozen = Module.new.freeze
    assert frozen.const_get(:HostCompatPosts).equal?(HostCompatPost)
    error = assert_raises(NameError) { frozen.const_get(:NoSuchThings) }
    refute_kind_of FrozenError, error
  end

  # --- schema migration ----------------------------------------------------

  def server_schema(fields)
    Parse::Schema::SchemaInfo.new("className" => "HostCompatBook", "fields" => fields)
  end

  def test_migration_handles_relation_and_pointer_target_classes
    migration = Parse::Schema::Migration.new(HostCompatBook, Parse::Schema::SchemaDiff.new(HostCompatBook, nil),
                                             client: Object.new)
    schema = migration.send(:build_schema)
    assert_equal({ "type" => "Relation", "targetClass" => "_User" }, schema["fields"]["fans"])
    assert_equal({ "type" => "Pointer", "targetClass" => "HostCompatAuthor" },
                 schema["fields"]["hostCompatAuthor"])
    ops = migration.operations
    pointer_op = ops.find { |o| o[:field] == "hostCompatAuthor" }
    assert_equal "HostCompatAuthor", pointer_op[:target_class]
    assert_equal "Relation", ops.find { |o| o[:field] == "fans" }[:type]
  end

  def test_add_field_definitions_carry_target_class
    definition = Parse::Schema.field_definition_for(HostCompatBook, :host_compat_author, "hostCompatAuthor")
    assert_equal({ "type" => "Pointer", "targetClass" => "HostCompatAuthor" }, definition)
  end

  def test_sdk_only_types_map_to_their_storage_columns
    schema = Parse::Schema::Migration.new(HostCompatBook, Parse::Schema::SchemaDiff.new(HostCompatBook, nil),
                                          client: Object.new).send(:build_schema)
    assert_equal "Array", schema["fields"]["embedding"]["type"]
    %w[tz phone mail].each { |f| assert_equal "String", schema["fields"][f]["type"], f }
    assert_equal "Array", HostCompatBook.schema[:fields][:embedding][:type]
    assert_equal "String", HostCompatBook.schema[:fields][:phone][:type]
  end

  def test_diff_in_sync_for_sdk_only_types_and_relations
    diff = Parse::Schema::SchemaDiff.new(HostCompatBook, server_schema(
      "title" => { "type" => "String" },
      "hostCompatAuthor" => { "type" => "Pointer", "targetClass" => "HostCompatAuthor" },
      "fans" => { "type" => "Relation", "targetClass" => "_User" },
      "embedding" => { "type" => "Array" },
      "tz" => { "type" => "String" },
      "phone" => { "type" => "String" },
      "mail" => { "type" => "String" },
    ))
    assert_empty diff.type_mismatches
    assert_empty diff.missing_on_server
    assert_empty diff.missing_locally
    assert diff.in_sync?
  end

  # --- model builder -------------------------------------------------------

  def build(name, fields)
    out = nil
    _, err = capture_io { out = Parse::Model::Builder.build!("className" => name, "fields" => fields) }
    [out, err]
  end

  def test_builder_renames_columns_that_clash_with_ruby_methods
    klass, err = build("HostCompatGenA", "class" => { "type" => "String" }, "hash" => { "type" => "String" },
                                         "send" => { "type" => "Pointer", "targetClass" => "HostCompatGenA" })
    assert_equal "HostCompatGenA", klass.parse_class
    assert_equal :class, klass.field_map[:class_field]
    assert_equal :hash, klass.field_map[:hash_field]
    assert_equal :send, klass.field_map[:send_field]
    assert_match(/exposed as #class_field/, err)
    obj = klass.new("objectId" => "a1", "class" => "c", "hash" => "h")
    assert_equal klass, obj.class
    assert_kind_of Integer, obj.hash
    assert_equal "c", obj.class_field
    assert_equal "h", obj.hash_field
  end

  def test_builder_skips_a_column_whose_underscored_name_is_taken
    klass, err = build("HostCompatGenB", "fooBar" => { "type" => "String" }, "foo_bar" => { "type" => "Number" })
    assert_equal :fooBar, klass.field_map[:foo_bar]
    assert_match(/skipping column HostCompatGenB\.foo_bar/, err)
  end

  def test_builder_renames_boolean_scope_that_would_shadow_a_class_method
    klass, = build("HostCompatGenC", "name" => { "type" => "Boolean" })
    assert_equal :name, klass.field_map[:name_field]
    assert_equal "Parse::Generated::HostCompatGenC", klass.name
  end

  # --- naming --------------------------------------------------------------

  def test_parse_user_model_name_is_relative_to_parse
    name = Parse::User.model_name
    assert_equal "Parse::User", name.name
    assert_equal "user", name.param_key
    assert_equal "users", name.route_key
    assert_equal "_User", Parse::User.parse_class
  end
end
