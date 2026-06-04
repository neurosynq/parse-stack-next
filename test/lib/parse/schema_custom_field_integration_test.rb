# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../support/test_server"

# Live integration coverage for the migration wire-name fix (5.2.0).
#
# Regression target: the migrator previously derived every wire column with
# `camelize(:lower)`, which ignored custom `field:` mappings — so a model with
# `property :display_name, field: "display_label"` got a PHANTOM `displayName`
# column created on the server instead of the declared `display_label`, and a
# multi-word property was emitted twice. The fix resolves wire names through
# `field_map`. These tests apply a real migration against the running Parse
# Server and prove the correct columns are created and a save round-trips.
#
# Gated on PARSE_TEST_USE_DOCKER like the rest of the live-server suite.
class SchemaCustomFieldIntegrationTest < Minitest::Test
  class SchemaCustomFieldInv < Parse::Object
    parse_class "SchemaCustomFieldInv"
    property :sku, :string
    property :unit_price, :integer                          # default wire -> "unitPrice"
    property :display_name, :string, field: "display_label" # custom wire  -> "display_label"
  end

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    Parse::Test::ServerHelper.setup
  end

  def test_auto_upgrade_creates_true_wire_columns_not_phantoms
    SchemaCustomFieldInv.auto_upgrade!

    info = Parse::Schema.fetch("SchemaCustomFieldInv")
    assert info.has_field?("unitPrice"),
           "a multi-word property must create its camelCase wire column (unitPrice)"
    assert info.has_field?("display_label"),
           "a custom `field:` mapping must create the declared wire column (display_label)"
    refute info.has_field?("displayName"),
           "the migrator must NOT create a phantom camelCase column for a custom `field:` mapping"
  end

  def test_save_round_trips_through_custom_mapped_property
    SchemaCustomFieldInv.auto_upgrade!

    obj = SchemaCustomFieldInv.new(sku: "SKU-1", unit_price: 1299, display_name: "Widget")
    assert obj.save, "object using a custom-mapped property must save"

    fetched = SchemaCustomFieldInv.query(:objectId => obj.id).first
    refute_nil fetched, "saved object must be retrievable"
    assert_equal "Widget", fetched.display_name,
           "value written via display_name must round-trip through the display_label column"
    assert_equal 1299, fetched.unit_price
  ensure
    obj&.destroy
  end

  def test_diff_converges_and_migration_not_needed_after_auto_upgrade
    SchemaCustomFieldInv.auto_upgrade!

    diff = Parse::Schema.diff(SchemaCustomFieldInv)
    assert diff.missing_on_server.empty?,
           "no fields should be missing on the server after auto_upgrade!: #{diff.missing_on_server.inspect}"
    assert diff.server_covers_local?,
           "server must cover the local model after auto_upgrade!"
    refute Parse::Schema.migration(SchemaCustomFieldInv).needed?,
           "migration must not be needed once the schema has converged"
  end
end
