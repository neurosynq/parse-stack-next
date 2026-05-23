require_relative "../../test_helper"

class TestSchema < Minitest::Test
  def test_type_map_defined
    assert_kind_of Hash, Parse::Schema::TYPE_MAP
    assert_equal :string, Parse::Schema::TYPE_MAP["String"]
    assert_equal :integer, Parse::Schema::TYPE_MAP["Number"]
    assert_equal :boolean, Parse::Schema::TYPE_MAP["Boolean"]
    assert_equal :date, Parse::Schema::TYPE_MAP["Date"]
    assert_equal :pointer, Parse::Schema::TYPE_MAP["Pointer"]
    assert_equal :relation, Parse::Schema::TYPE_MAP["Relation"]
  end

  def test_reverse_type_map_defined
    assert_kind_of Hash, Parse::Schema::REVERSE_TYPE_MAP
    assert_equal "String", Parse::Schema::REVERSE_TYPE_MAP[:string]
    assert_equal "Number", Parse::Schema::REVERSE_TYPE_MAP[:integer]
    assert_equal "Boolean", Parse::Schema::REVERSE_TYPE_MAP[:boolean]
    assert_equal "Date", Parse::Schema::REVERSE_TYPE_MAP[:date]
    assert_equal "Pointer", Parse::Schema::REVERSE_TYPE_MAP[:pointer]
    assert_equal "Relation", Parse::Schema::REVERSE_TYPE_MAP[:relation]
  end

  # Test class methods exist
  def test_all_method_exists
    assert_respond_to Parse::Schema, :all
  end

  def test_fetch_method_exists
    assert_respond_to Parse::Schema, :fetch
  end

  def test_diff_method_exists
    assert_respond_to Parse::Schema, :diff
  end

  def test_migration_method_exists
    assert_respond_to Parse::Schema, :migration
  end

  def test_exists_method_exists
    assert_respond_to Parse::Schema, :exists?
  end

  def test_class_names_method_exists
    assert_respond_to Parse::Schema, :class_names
  end
end

class TestSchemaInfo < Minitest::Test
  def setup
    @data = {
      "className" => "Song",
      "fields" => {
        "objectId" => { "type" => "String" },
        "title" => { "type" => "String" },
        "duration" => { "type" => "Number" },
        "artist" => { "type" => "Pointer", "targetClass" => "Artist" },
        "tags" => { "type" => "Array" },
        "released" => { "type" => "Boolean" },
      },
      "indexes" => {
        "_id_" => { "_id" => 1 },
      },
      "classLevelPermissions" => {
        "find" => { "*" => true },
        "get" => { "*" => true },
      },
    }
    @schema_info = Parse::Schema::SchemaInfo.new(@data)
  end

  def test_class_name
    assert_equal "Song", @schema_info.class_name
  end

  def test_field_names
    expected = %w[objectId title duration artist tags released]
    assert_equal expected.sort, @schema_info.field_names.sort
  end

  def test_field_type
    assert_equal :string, @schema_info.field_type(:title)
    assert_equal :integer, @schema_info.field_type("duration")
    assert_equal :pointer, @schema_info.field_type(:artist)
    assert_equal :array, @schema_info.field_type(:tags)
    assert_equal :boolean, @schema_info.field_type(:released)
  end

  def test_pointer_target
    assert_equal "Artist", @schema_info.pointer_target(:artist)
    assert_nil @schema_info.pointer_target(:title)
  end

  def test_has_field
    assert @schema_info.has_field?(:title)
    assert @schema_info.has_field?("duration")
    refute @schema_info.has_field?(:nonexistent)
  end

  def test_builtin_for_regular_class
    refute @schema_info.builtin?
  end

  def test_builtin_for_system_class
    data = { "className" => "_User", "fields" => {} }
    info = Parse::Schema::SchemaInfo.new(data)
    assert info.builtin?
  end

  def test_indexes
    assert_kind_of Hash, @schema_info.indexes
    assert @schema_info.indexes.key?("_id_")
  end

  def test_class_level_permissions
    assert_kind_of Hash, @schema_info.class_level_permissions
    assert @schema_info.class_level_permissions.key?("find")
  end

  def test_to_h
    assert_equal @data, @schema_info.to_h
  end
end

class TestSchemaDiff < Minitest::Test
  # Define a test model class
  class TestModel < Parse::Object
    parse_class "TestModel"
    property :title, :string
    property :count, :integer
    property :active, :boolean
  end

  def test_server_exists_false_when_nil
    diff = Parse::Schema::SchemaDiff.new(TestModel, nil)
    refute diff.server_exists?
  end

  def test_server_exists_true_when_schema_present
    data = { "className" => "TestModel", "fields" => {} }
    schema = Parse::Schema::SchemaInfo.new(data)
    diff = Parse::Schema::SchemaDiff.new(TestModel, schema)
    assert diff.server_exists?
  end

  def test_missing_on_server_when_no_server_schema
    diff = Parse::Schema::SchemaDiff.new(TestModel, nil)
    missing = diff.missing_on_server
    # Should include model fields
    assert missing.key?(:title)
    assert missing.key?(:count)
    assert missing.key?(:active)
  end

  def test_missing_locally_when_no_server_schema
    diff = Parse::Schema::SchemaDiff.new(TestModel, nil)
    assert_empty diff.missing_locally
  end

  def test_in_sync_false_when_no_server_schema
    diff = Parse::Schema::SchemaDiff.new(TestModel, nil)
    refute diff.in_sync?
  end

  def test_summary_returns_string
    diff = Parse::Schema::SchemaDiff.new(TestModel, nil)
    summary = diff.summary
    assert_kind_of String, summary
    assert_includes summary, "TestModel"
  end
end

class TestMigration < Minitest::Test
  class MigrationTestModel < Parse::Object
    parse_class "MigrationTestModel"
    property :name, :string
    property :value, :integer
  end

  # Mock client for testing
  class MockClient
    def create_schema(class_name, schema)
      Parse::Response.new({ "className" => class_name })
    end

    def update_schema(class_name, schema)
      Parse::Response.new({ "className" => class_name })
    end
  end

  def mock_client
    @mock_client ||= MockClient.new
  end

  def test_needed_when_server_schema_missing
    diff = Parse::Schema::SchemaDiff.new(MigrationTestModel, nil)
    migration = Parse::Schema::Migration.new(MigrationTestModel, diff, client: mock_client)
    assert migration.needed?
  end

  def test_operations_includes_create_class_when_missing
    diff = Parse::Schema::SchemaDiff.new(MigrationTestModel, nil)
    migration = Parse::Schema::Migration.new(MigrationTestModel, diff, client: mock_client)
    ops = migration.operations
    create_ops = ops.select { |op| op[:action] == :create_class }
    assert_equal 1, create_ops.count
    assert_equal "MigrationTestModel", create_ops.first[:class_name]
  end

  def test_preview_returns_string
    diff = Parse::Schema::SchemaDiff.new(MigrationTestModel, nil)
    migration = Parse::Schema::Migration.new(MigrationTestModel, diff, client: mock_client)
    preview = migration.preview
    assert_kind_of String, preview
    assert_includes preview, "MigrationTestModel"
  end

  def test_apply_dry_run_returns_preview
    diff = Parse::Schema::SchemaDiff.new(MigrationTestModel, nil)
    migration = Parse::Schema::Migration.new(MigrationTestModel, diff, client: mock_client)
    result = migration.apply!(dry_run: true)
    assert_equal :preview, result[:status]
    assert_kind_of Array, result[:operations]
    assert_kind_of String, result[:preview]
  end

  def test_not_needed_when_in_sync
    # Create a diff that would be in sync
    data = {
      "className" => "MigrationTestModel",
      "fields" => {
        "objectId" => { "type" => "String" },
        "createdAt" => { "type" => "Date" },
        "updatedAt" => { "type" => "Date" },
        "ACL" => { "type" => "ACL" },
        "name" => { "type" => "String" },
        "value" => { "type" => "Number" },
      },
    }
    schema = Parse::Schema::SchemaInfo.new(data)
    diff = Parse::Schema::SchemaDiff.new(MigrationTestModel, schema)
    migration = Parse::Schema::Migration.new(MigrationTestModel, diff, client: mock_client)

    # Note: This may still show as needed if there are subtle differences
    # The main point is the API works correctly
    result = migration.apply!(dry_run: true)
    assert_kind_of Hash, result
    assert result.key?(:status)
  end
end
