require_relative "../../../test_helper_integration"

# Live-server companion to group_by_class_delegator_test.rb. Split into its
# own *_integration_test.rb file so the Docker harness (included below) only
# loads under the integration suite — the unit half stays Docker-free and
# runs in rake test:unit / CI.
#
# Uses a distinct model name ("Gbdi" prefix) from the unit file's GbdPost so
# the two files can co-load in a single-process `rake test` run without
# re-registering the same Parse class.
class GbdiPost < Parse::Object
  parse_class "GbdiPost"
  property :category, :string
  property :score,    :integer
end

# These tests seed real records and assert that the class-method delegators
# produce the same results as calling the equivalent query-instance form.
class GroupByClassDelegatorIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def setup
    super

    # Seed a handful of GbdiPost objects across two categories.
    with_parse_server do
      3.times { |i| create_test_object("GbdiPost", category: "alpha", score: i + 1) }
      2.times { |i| create_test_object("GbdiPost", category: "beta",  score: i + 10) }
    end
  end

  def test_group_by_class_method_count_equals_query_instance_count
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      via_class = GbdiPost.group_by(:category).count
      via_query = GbdiPost.query.group_by(:category).count

      assert_equal via_query, via_class,
        "GbdiPost.group_by(:category).count should equal GbdiPost.query.group_by(:category).count"

      # Sanity-check the actual values: we seeded 3 alpha + 2 beta.
      assert_equal 3, via_class["alpha"], "expected 3 alpha records"
      assert_equal 2, via_class["beta"],  "expected 2 beta records"
    end
  end

  def test_group_by_kwargs_forward_sortable
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      result = GbdiPost.group_by(:category, sortable: true).count
      assert_kind_of Parse::GroupedResult, result,
        "sortable: true should return a Parse::GroupedResult (proves kwargs forwarded)"
    end
  end

  def test_group_by_date_class_method_count_equals_query_instance_count
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      via_class = GbdiPost.group_by_date(:created_at, :month).count
      via_query = GbdiPost.query.group_by_date(:created_at, :month).count

      assert_equal via_query, via_class,
        "GbdiPost.group_by_date(:created_at, :month).count should equal the query-instance form"

      # All 5 seeded objects share the same month bucket.
      total = via_class.values.sum
      assert_equal 5, total, "expected 5 total records across all month buckets"
    end
  end

  def test_group_by_date_kwargs_forward_sortable
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      result = GbdiPost.group_by_date(:created_at, :day, sortable: true).count
      assert_kind_of Parse::GroupedResult, result,
        "sortable: true should return a Parse::GroupedResult (proves kwargs forwarded for group_by_date)"
    end
  end
end
