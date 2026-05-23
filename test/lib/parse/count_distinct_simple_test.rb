require_relative "../../test_helper"

class TestCountDistinctSimple < Minitest::Test
  extend Minitest::Spec::DSL

  def test_count_distinct_method_exists
    query = Parse::Query.new("Song")
    assert_respond_to query, :count_distinct
  end

  def test_count_distinct_argument_validation
    query = Parse::Query.new("Song")
    
    # Test nil field validation
    assert_raises(ArgumentError) do
      query.count_distinct(nil)
    end
    
    # Test invalid field validation (object without to_s)
    invalid_field = Object.new
    def invalid_field.respond_to?(method)
      method != :to_s
    end
    
    assert_raises(ArgumentError) do
      query.count_distinct(invalid_field)
    end
  end

  def test_count_distinct_pipeline_construction
    # Test that the method constructs the proper pipeline
    query = Parse::Query.new("Song")
    
    # Mock the client to capture the pipeline
    captured_pipeline = nil
    mock_client = Object.new
    def mock_client.aggregate_pipeline(table, pipeline, **opts)
      @captured_pipeline = pipeline
      @captured_table = table
      response = Object.new
      def response.success?
        true
      end
      def response.result
        [{ "distinctCount" => 5 }]
      end
      response
    end
    
    def mock_client.captured_pipeline
      @captured_pipeline
    end
    
    def mock_client.captured_table
      @captured_table
    end
    
    query.client = mock_client
    
    # Test basic pipeline
    result = query.count_distinct(:genre)
    
    expected_pipeline = [
      { "$group" => { "_id" => "$genre" } },
      { "$count" => "distinctCount" }
    ]
    
    assert_equal expected_pipeline, mock_client.captured_pipeline
    assert_equal "Song", mock_client.captured_table
    assert_equal 5, result
  end

  def test_count_distinct_with_where_conditions
    query = Parse::Query.new("Song")
    query.where(:play_count.gt => 100)
    
    # Mock the client to capture the pipeline
    captured_pipeline = nil
    mock_client = Object.new
    def mock_client.aggregate_pipeline(table, pipeline, **opts)
      @captured_pipeline = pipeline
      response = Object.new
      def response.success?
        true
      end
      def response.result
        [{ "distinctCount" => 3 }]
      end
      response
    end
    
    def mock_client.captured_pipeline
      @captured_pipeline
    end
    
    query.client = mock_client
    
    result = query.count_distinct(:artist)
    
    # Should include match stage for where conditions
    expected_pipeline = [
      { "$match" => { "playCount" => { :$gt => 100 } } },
      { "$group" => { "_id" => "$artist" } },
      { "$count" => "distinctCount" }
    ]
    
    assert_equal expected_pipeline, mock_client.captured_pipeline
    assert_equal 3, result
  end

  def test_count_distinct_field_formatting
    query = Parse::Query.new("Song")
    
    mock_client = Object.new
    def mock_client.aggregate_pipeline(table, pipeline, **opts)
      @captured_pipeline = pipeline
      response = Object.new
      def response.success?
        true
      end
      def response.result
        [{ "distinctCount" => 2 }]
      end
      response
    end
    
    def mock_client.captured_pipeline
      @captured_pipeline
    end
    
    query.client = mock_client
    
    # Test that snake_case field gets formatted properly
    result = query.count_distinct(:play_count)
    
    # Field should be formatted according to Parse conventions (snake_case -> camelCase)
    expected_pipeline = [
      { "$group" => { "_id" => "$playCount" } },
      { "$count" => "distinctCount" }
    ]
    
    assert_equal expected_pipeline, mock_client.captured_pipeline
    assert_equal 2, result
  end
end