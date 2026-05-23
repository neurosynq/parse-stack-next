require_relative "../../../test_helper"

# Define a test model for count_distinct testing
class Song < Parse::Object
  property :title
  property :genre
  property :artist
  property :play_count, :integer
end

class TestCountDistinctModel < Minitest::Test
  extend Minitest::Spec::DSL

  def test_model_count_distinct_basic
    # Test that the method exists and basic functionality works
    mock_client = create_mock_client_with_response([{ "distinctCount" => 8 }])

    query = Song.query
    query.client = mock_client

    result = query.count_distinct(:genre)
    assert_equal 8, result
  end

  def test_model_count_distinct_with_constraints
    # Test with constraints (though mocked)
    mock_client = create_mock_client_with_response([{ "distinctCount" => 4 }])

    query = Song.query(:play_count.gt => 1000)
    query.client = mock_client

    result = query.count_distinct(:artist)
    assert_equal 4, result
  end

  def test_model_count_distinct_multiple_constraints
    # Test with multiple constraints
    mock_client = create_mock_client_with_response([{ "distinctCount" => 2 }])

    query = Song.query(:play_count.gt => 500, :genre => "rock")
    query.client = mock_client

    result = query.count_distinct(:artist)
    assert_equal 2, result
  end

  def test_model_count_distinct_zero_result
    # Test with empty results
    mock_client = create_mock_client_with_response([])

    query = Song.query
    query.client = mock_client

    result = query.count_distinct(:genre)
    assert_equal 0, result
  end

  def test_count_distinct_method_exists_on_model
    assert_respond_to Song, :count_distinct
  end

  private

  def create_mock_client_with_response(response_data)
    mock_client = Object.new

    def mock_client.aggregate_pipeline(table, pipeline, **opts)
      response = Object.new
      def response.success?
        true
      end

      # Capture response_data in the closure
      response_data = @response_data
      def response.result
        response_data
      end

      response
    end

    # Set the response data as an instance variable
    mock_client.instance_variable_set(:@response_data, response_data)

    # Make response_data accessible to the aggregate_pipeline method
    mock_client.define_singleton_method(:set_response_data) do |data|
      @response_data = data
    end

    # Update the aggregate_pipeline method to use the instance variable
    mock_client.define_singleton_method(:aggregate_pipeline) do |table, pipeline, **opts|
      response = Object.new
      response_data = @response_data

      response.define_singleton_method(:success?) { true }
      response.define_singleton_method(:result) { response_data }
      response
    end

    mock_client
  end
end
