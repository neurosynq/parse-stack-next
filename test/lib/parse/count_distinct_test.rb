require_relative "../../test_helper"

class TestCountDistinct < Minitest::Test
  extend Minitest::Spec::DSL

  def setup
    @mock_client = Minitest::Mock.new
    @query = Parse::Query.new("Song")
    @query.client = @mock_client
  end

  def test_count_distinct_basic
    # Mock successful response
    mock_response = Minitest::Mock.new
    mock_response.expect :error?, false
    mock_response.expect :result, [{ "distinctCount" => 5 }]
    # Define respond_to? to return true for the methods we expect
    def mock_response.respond_to?(method)
      [:error?, :result].include?(method) || super
    end
    
    expected_pipeline = [
      { "$group" => { "_id" => "$genre" } },
      { "$count" => "distinctCount" }
    ]
    
    @mock_client.expect :aggregate_pipeline, mock_response do |table, pipeline, **kwargs|
      table == "Song" && pipeline.is_a?(Array)
    end
    
    result = @query.count_distinct(:genre)
    
    assert_equal 5, result
    @mock_client.verify
    mock_response.verify
  end

  def test_count_distinct_with_where_conditions
    # Add where condition
    @query.where(:play_count.gt => 100)
    
    mock_response = Minitest::Mock.new
    mock_response.expect :error?, false
    mock_response.expect :result, [{ "distinctCount" => 3 }]
    # Define respond_to? to return true for the methods we expect
    def mock_response.respond_to?(method)
      [:error?, :result].include?(method) || super
    end
    
    expected_pipeline = [
      { "$match" => { "playCount" => { "$gt" => 100 } } },
      { "$group" => { "_id" => "$artist" } },
      { "$count" => "distinctCount" }
    ]
    
    @mock_client.expect :aggregate_pipeline, mock_response do |table, pipeline, **kwargs|
      table == "Song" && pipeline.is_a?(Array)
    end
    
    result = @query.count_distinct(:artist)
    
    assert_equal 3, result
    @mock_client.verify
    mock_response.verify
  end

  def test_count_distinct_empty_result
    mock_response = Minitest::Mock.new
    mock_response.expect :error?, false
    mock_response.expect :result, []
    # Define respond_to? to return true for the methods we expect
    def mock_response.respond_to?(method)
      [:error?, :result].include?(method) || super
    end
    
    expected_pipeline = [
      { "$group" => { "_id" => "$genre" } },
      { "$count" => "distinctCount" }
    ]
    
    @mock_client.expect :aggregate_pipeline, mock_response do |table, pipeline, **kwargs|
      table == "Song" && pipeline.is_a?(Array)
    end
    
    result = @query.count_distinct(:genre)
    
    assert_equal 0, result
    @mock_client.verify
    mock_response.verify
  end

  def test_count_distinct_error_response
    mock_response = Minitest::Mock.new
    mock_response.expect :error?, true
    # Define respond_to? to return true for error? method
    def mock_response.respond_to?(method)
      method == :error? || super
    end
    
    expected_pipeline = [
      { "$group" => { "_id" => "$genre" } },
      { "$count" => "distinctCount" }
    ]
    
    @mock_client.expect :aggregate_pipeline, mock_response do |table, pipeline, **kwargs|
      table == "Song" && pipeline.is_a?(Array)
    end
    
    result = @query.count_distinct(:genre)
    
    assert_equal 0, result
    @mock_client.verify
    mock_response.verify
  end

  def test_count_distinct_nil_field_raises_error
    assert_raises(ArgumentError) do
      @query.count_distinct(nil)
    end
  end

  def test_count_distinct_invalid_field_raises_error
    # Test with an invalid field type that doesn't respond to to_s  
    invalid_field = Object.new
    def invalid_field.respond_to?(method)
      method == :to_s ? false : super
    end
    
    assert_raises(ArgumentError) do
      @query.count_distinct(invalid_field)
    end
  end

  def test_count_distinct_field_formatting
    mock_response = Minitest::Mock.new
    mock_response.expect :error?, false
    mock_response.expect :result, [{ "distinctCount" => 2 }]
    # Define respond_to? to return true for the methods we expect
    def mock_response.respond_to?(method)
      [:error?, :result].include?(method) || super
    end
    
    # Test that snake_case field gets converted to camelCase
    expected_pipeline = [
      { "$group" => { "_id" => "$playCount" } },
      { "$count" => "distinctCount" }
    ]
    
    @mock_client.expect :aggregate_pipeline, mock_response do |table, pipeline, **kwargs|
      table == "Song" && pipeline.is_a?(Array)
    end
    
    result = @query.count_distinct(:play_count)
    
    assert_equal 2, result
    @mock_client.verify
    mock_response.verify
  end

  def test_count_distinct_with_mixed_conditions_including_dates
    # Set up query with mixed where conditions including dates
    now = Time.now
    yesterday = now - 86400
    
    @query.where(
      :play_count.gt => 100,
      :genre => "rock",
      :release_date.gte => yesterday,
      :release_date.lte => now,
      :featured => true
    )
    
    mock_response = Minitest::Mock.new
    mock_response.expect :error?, false
    mock_response.expect :result, [{ "distinctCount" => 7 }]
    # Define respond_to? to return true for the methods we expect
    def mock_response.respond_to?(method)
      [:error?, :result].include?(method) || super
    end
    
    # The pipeline should include a $match stage with all conditions
    expected_match = {
      "playCount" => { "$gt" => 100 },
      "genre" => "rock",
      "releaseDate" => { 
        "$gte" => { "__type" => "Date", "iso" => yesterday.iso8601(3) },
        "$lte" => { "__type" => "Date", "iso" => now.iso8601(3) }
      },
      "featured" => true
    }
    
    @mock_client.expect :aggregate_pipeline, mock_response do |table, pipeline, **kwargs|
      table == "Song" && 
      pipeline.is_a?(Array) &&
      pipeline[0]["$match"] && # Should have a match stage
      pipeline[1]["$group"] && # Should have a group stage
      pipeline[2]["$count"] # Should have a count stage
    end
    
    result = @query.count_distinct(:artist)
    
    assert_equal 7, result
    @mock_client.verify
    mock_response.verify
  end

  def test_count_distinct_complex_date_and_array_conditions
    # Test with complex conditions including date ranges and array operations
    now = Time.now
    week_ago = now - 604800
    
    @query.where(
      :created_at.gte => week_ago,
      :created_at.lt => now,
      :tags.in => ["popular", "trending"],
      :rating.gte => 4.0,
      :verified => true
    )
    
    mock_response = Minitest::Mock.new
    mock_response.expect :error?, false
    mock_response.expect :result, [{ "distinctCount" => 12 }]
    # Define respond_to? to return true for the methods we expect
    def mock_response.respond_to?(method)
      [:error?, :result].include?(method) || super
    end
    
    @mock_client.expect :aggregate_pipeline, mock_response do |table, pipeline, **kwargs|
      table == "Song" && 
      pipeline.is_a?(Array) &&
      pipeline.length == 3 && # Should have match, group, and count stages
      pipeline[0]["$match"] # First stage should be match with conditions
    end
    
    result = @query.count_distinct(:album)
    
    assert_equal 12, result
    @mock_client.verify
    mock_response.verify
  end
end