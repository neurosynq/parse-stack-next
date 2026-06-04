require_relative "../../../test_helper_integration"

# Model used only by this test file. Prefixed with "Gbd" to avoid collisions
# with any other class registered during the same test run.
class GbdPost < Parse::Object
  parse_class "GbdPost"
  property :category, :string
  property :score,    :integer
end

# ── Unit tests: no server required ───────────────────────────────────────────
# These tests verify that the class-method delegators exist and return the
# correct types without making any network calls.

class GroupByClassDelegatorUnitTest < Minitest::Test
  def test_class_responds_to_group_by
    assert_respond_to GbdPost, :group_by,
      "GbdPost.group_by should be defined as a class method"
  end

  def test_class_responds_to_group_by_date
    assert_respond_to GbdPost, :group_by_date,
      "GbdPost.group_by_date should be defined as a class method"
  end

  def test_group_by_returns_group_by_instance
    result = GbdPost.group_by(:category)
    assert_kind_of Parse::GroupBy, result,
      "GbdPost.group_by(:category) should return a Parse::GroupBy"
  end

  def test_group_by_sortable_returns_sortable_group_by_instance
    result = GbdPost.group_by(:category, sortable: true)
    assert_kind_of Parse::SortableGroupBy, result,
      "GbdPost.group_by(:category, sortable: true) should return a Parse::SortableGroupBy"
  end

  def test_group_by_date_returns_group_by_date_instance
    result = GbdPost.group_by_date(:created_at, :month)
    assert_kind_of Parse::GroupByDate, result,
      "GbdPost.group_by_date(:created_at, :month) should return a Parse::GroupByDate"
  end

  def test_group_by_date_sortable_returns_sortable_instance
    result = GbdPost.group_by_date(:created_at, :day, sortable: true)
    assert_kind_of Parse::SortableGroupByDate, result,
      "GbdPost.group_by_date(:created_at, :day, sortable: true) should return a Parse::SortableGroupByDate"
  end
end

# ── Integration tests: live server required ───────────────────────────────────
# These tests seed real records and assert that the class-method delegators
# produce the same results as calling the equivalent query-instance form.

class GroupByClassDelegatorIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def setup
    super

    # Seed a handful of GbdPost objects across two categories.
    with_parse_server do
      3.times { |i| create_test_object("GbdPost", category: "alpha", score: i + 1) }
      2.times { |i| create_test_object("GbdPost", category: "beta",  score: i + 10) }
    end
  end

  def test_group_by_class_method_count_equals_query_instance_count
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      via_class = GbdPost.group_by(:category).count
      via_query = GbdPost.query.group_by(:category).count

      assert_equal via_query, via_class,
        "GbdPost.group_by(:category).count should equal GbdPost.query.group_by(:category).count"

      # Sanity-check the actual values: we seeded 3 alpha + 2 beta.
      assert_equal 3, via_class["alpha"], "expected 3 alpha records"
      assert_equal 2, via_class["beta"],  "expected 2 beta records"
    end
  end

  def test_group_by_kwargs_forward_sortable
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      result = GbdPost.group_by(:category, sortable: true).count
      assert_kind_of Parse::GroupedResult, result,
        "sortable: true should return a Parse::GroupedResult (proves kwargs forwarded)"
    end
  end

  def test_group_by_date_class_method_count_equals_query_instance_count
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      via_class = GbdPost.group_by_date(:created_at, :month).count
      via_query = GbdPost.query.group_by_date(:created_at, :month).count

      assert_equal via_query, via_class,
        "GbdPost.group_by_date(:created_at, :month).count should equal the query-instance form"

      # All 5 seeded objects share the same month bucket.
      total = via_class.values.sum
      assert_equal 5, total, "expected 5 total records across all month buckets"
    end
  end

  def test_group_by_date_kwargs_forward_sortable
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      result = GbdPost.group_by_date(:created_at, :day, sortable: true).count
      assert_kind_of Parse::GroupedResult, result,
        "sortable: true should return a Parse::GroupedResult (proves kwargs forwarded for group_by_date)"
    end
  end
end
