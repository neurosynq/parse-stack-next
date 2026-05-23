require_relative "../../../../test_helper"

class TestRangeOperatorCombination < Minitest::Test
  def setup
    @query = Parse::Query.new("Post")
  end

  def test_integration_with_model_query
    # Test that the same behavior works with model queries
    time1 = Time.new(2023, 1, 1, 0, 0, 0, 0)
    time2 = Time.new(2023, 12, 31, 23, 59, 59, 0)
    
    # Test using Parse::Query directly with same method calls
    query = Parse::Query.new("Post")
    query.where(:created_at.gte => time1)
    query.where(:created_at.lte => time2)
    
    compiled = query.compile_where
    
    # Both operators should be present
    assert compiled.key?("createdAt"), "Should have createdAt field"
    assert compiled["createdAt"].key?(:$gte), "Should have $gte operator"
    assert compiled["createdAt"].key?(:$lte), "Should have $lte operator"
    
    expected_start = { :__type => "Date", :iso => time1.utc.iso8601(3) }
    expected_end = { :__type => "Date", :iso => time2.utc.iso8601(3) }
    
    assert_equal expected_start, compiled["createdAt"][:$gte]
    assert_equal expected_end, compiled["createdAt"][:$lte]
  end

  def test_gte_and_lte_work_together_on_same_field
    time1 = Time.new(2023, 1, 1, 0, 0, 0, 0)
    time2 = Time.new(2023, 12, 31, 23, 59, 59, 0)
    
    # Add both gte and lte constraints on created_at field
    @query.where(:created_at.gte => time1, :created_at.lte => time2)
    
    compiled = @query.compile_where
    
    # Both operators should be present in the same constraint object
    # Note: created_at gets converted to createdAt by Parse field formatter
    assert compiled.key?("createdAt"), "Should have createdAt field"
    assert compiled["createdAt"].key?(:$gte), "Should have $gte operator"
    assert compiled["createdAt"].key?(:$lte), "Should have $lte operator"
    
    # Check the values are properly formatted
    expected_start = { :__type => "Date", :iso => time1.utc.iso8601(3) }
    expected_end = { :__type => "Date", :iso => time2.utc.iso8601(3) }
    
    assert_equal expected_start, compiled["createdAt"][:$gte]
    assert_equal expected_end, compiled["createdAt"][:$lte]
  end

  def test_gte_and_lte_sequential_addition
    time1 = Time.new(2023, 1, 1, 0, 0, 0, 0)
    time2 = Time.new(2023, 12, 31, 23, 59, 59, 0)
    
    # Add constraints sequentially
    @query.where(:created_at.gte => time1)
    @query.where(:created_at.lte => time2)
    
    compiled = @query.compile_where
    
    # Both operators should be present
    assert compiled.key?("createdAt"), "Should have createdAt field"
    assert compiled["createdAt"].key?(:$gte), "Should have $gte operator"
    assert compiled["createdAt"].key?(:$lte), "Should have $lte operator"
    
    expected_start = { :__type => "Date", :iso => time1.utc.iso8601(3) }
    expected_end = { :__type => "Date", :iso => time2.utc.iso8601(3) }
    
    assert_equal expected_start, compiled["createdAt"][:$gte]
    assert_equal expected_end, compiled["createdAt"][:$lte]
  end

  def test_gt_and_lt_work_together
    @query.where(:likes.gt => 10, :likes.lt => 100)
    
    compiled = @query.compile_where
    
    assert compiled.key?("likes"), "Should have likes field"
    assert compiled["likes"].key?(:$gt), "Should have $gt operator"
    assert compiled["likes"].key?(:$lt), "Should have $lt operator"
    assert_equal 10, compiled["likes"][:$gt]
    assert_equal 100, compiled["likes"][:$lt]
  end

  def test_mixed_operators_on_same_field
    time1 = Time.new(2023, 6, 1, 0, 0, 0, 0)
    time2 = Time.new(2023, 6, 30, 23, 59, 59, 0)
    
    # Mix gte/lte with ne
    @query.where(:created_at.gte => time1, :created_at.lte => time2, :created_at.ne => nil)
    
    compiled = @query.compile_where
    
    assert compiled.key?("createdAt"), "Should have createdAt field"
    assert compiled["createdAt"].key?(:$gte), "Should have $gte operator"
    assert compiled["createdAt"].key?(:$lte), "Should have $lte operator"
    assert compiled["createdAt"].key?(:$ne), "Should have $ne operator"
    
    expected_start = { :__type => "Date", :iso => time1.utc.iso8601(3) }
    expected_end = { :__type => "Date", :iso => time2.utc.iso8601(3) }
    
    assert_equal expected_start, compiled["createdAt"][:$gte]
    assert_equal expected_end, compiled["createdAt"][:$lte]
    assert_nil compiled["createdAt"][:$ne]
  end

  def test_multiple_fields_with_range_operators
    time1 = Time.new(2023, 1, 1, 0, 0, 0, 0)
    time2 = Time.new(2023, 12, 31, 23, 59, 59, 0)
    
    @query.where(
      :created_at.gte => time1, 
      :created_at.lte => time2,
      :likes.gte => 50,
      :likes.lte => 500
    )
    
    compiled = @query.compile_where
    
    # Check created_at constraints
    assert compiled.key?("createdAt"), "Should have createdAt field"
    assert compiled["createdAt"].key?(:$gte), "createdAt should have $gte"
    assert compiled["createdAt"].key?(:$lte), "createdAt should have $lte"
    
    # Check likes constraints
    assert compiled.key?("likes"), "Should have likes field"
    assert compiled["likes"].key?(:$gte), "likes should have $gte"
    assert compiled["likes"].key?(:$lte), "likes should have $lte"
    assert_equal 50, compiled["likes"][:$gte]
    assert_equal 500, compiled["likes"][:$lte]
  end

  def test_overwriting_same_operator
    time1 = Time.new(2023, 1, 1, 0, 0, 0, 0)
    time2 = Time.new(2023, 6, 1, 0, 0, 0, 0)
    
    # Add gte twice - second should overwrite first
    @query.where(:created_at.gte => time1)
    @query.where(:created_at.gte => time2)
    
    compiled = @query.compile_where
    
    assert compiled.key?("createdAt"), "Should have createdAt field"
    assert compiled["createdAt"].key?(:$gte), "Should have $gte operator"
    
    # Should have the second time value
    expected = { :__type => "Date", :iso => time2.utc.iso8601(3) }
    assert_equal expected, compiled["createdAt"][:$gte]
  end

  def test_between_dates_helper_method
    time1 = Time.new(2023, 1, 1, 0, 0, 0, 0)
    time2 = Time.new(2023, 12, 31, 23, 59, 59, 0)
    
    # Using the between_dates constraint
    @query.where(:created_at.between_dates => [time1, time2])
    
    compiled = @query.compile_where
    
    # Should create both gte and lte constraints
    assert compiled.key?("createdAt"), "Should have createdAt field"
    assert compiled["createdAt"].key?(:$gte), "Should have $gte operator"
    assert compiled["createdAt"].key?(:$lte), "Should have $lte operator"
    
    expected_start = { :__type => "Date", :iso => time1.utc.iso8601(3) }
    expected_end = { :__type => "Date", :iso => time2.utc.iso8601(3) }
    
    assert_equal expected_start, compiled["createdAt"][:$gte]
    assert_equal expected_end, compiled["createdAt"][:$lte]
  end

  def test_alternative_syntax_split_where_calls
    time1 = Time.new(2023, 1, 1, 0, 0, 0, 0)
    time2 = Time.new(2023, 12, 31, 23, 59, 59, 0)
    
    # The syntax :created_at > x needs to be split into separate where calls
    # because Ruby can't evaluate :symbol > value directly
    @query.where(:created_at.gt => time1)
    @query.where(:created_at.lt => time2)
    
    compiled = @query.compile_where
    
    # Both operators should be present
    assert compiled.key?("createdAt"), "Should have createdAt field"
    assert compiled["createdAt"].key?(:$gt), "Should have $gt operator"
    assert compiled["createdAt"].key?(:$lt), "Should have $lt operator"
    
    expected_start = { :__type => "Date", :iso => time1.utc.iso8601(3) }
    expected_end = { :__type => "Date", :iso => time2.utc.iso8601(3) }
    
    assert_equal expected_start, compiled["createdAt"][:$gt]
    assert_equal expected_end, compiled["createdAt"][:$lt]
  end
end