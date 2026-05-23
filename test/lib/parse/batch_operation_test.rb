require_relative "../../test_helper"

class TestBatchOperation < Minitest::Test
  def setup
    @batch = Parse::BatchOperation.new
  end

  def test_initialize_without_transaction
    batch = Parse::BatchOperation.new
    assert_equal false, batch.transaction
    assert_empty batch.requests
    assert_empty batch.responses
  end

  def test_initialize_with_transaction
    batch = Parse::BatchOperation.new(nil, transaction: true)
    assert_equal true, batch.transaction
    assert_empty batch.requests
    assert_empty batch.responses
  end

  def test_initialize_with_requests
    req1 = Parse::Request.new(:post, "/classes/Test", body: { field: "value1" })
    req2 = Parse::Request.new(:post, "/classes/Test", body: { field: "value2" })

    batch = Parse::BatchOperation.new([req1, req2])
    assert_equal 2, batch.requests.count
    assert_equal false, batch.transaction
  end

  def test_initialize_with_requests_and_transaction
    req1 = Parse::Request.new(:post, "/classes/Test", body: { field: "value1" })
    req2 = Parse::Request.new(:post, "/classes/Test", body: { field: "value2" })

    batch = Parse::BatchOperation.new([req1, req2], transaction: true)
    assert_equal 2, batch.requests.count
    assert_equal true, batch.transaction
  end

  def test_as_json_without_transaction
    req = Parse::Request.new(:post, "/classes/Test", body: { field: "value" })
    batch = Parse::BatchOperation.new([req])

    json = batch.as_json
    assert_equal 1, json["requests"].count
    refute json.key?("transaction")
  end

  def test_as_json_with_transaction_false
    req = Parse::Request.new(:post, "/classes/Test", body: { field: "value" })
    batch = Parse::BatchOperation.new([req], transaction: false)

    json = batch.as_json
    assert_equal 1, json["requests"].count
    refute json.key?("transaction")
  end

  def test_as_json_with_transaction_true
    req = Parse::Request.new(:post, "/classes/Test", body: { field: "value" })
    batch = Parse::BatchOperation.new([req], transaction: true)

    json = batch.as_json
    assert_equal 1, json["requests"].count
    assert json.key?("transaction")
    assert_equal true, json["transaction"]
  end

  def test_add_request
    req1 = Parse::Request.new(:post, "/classes/Test", body: { field: "value1" })
    req2 = Parse::Request.new(:post, "/classes/Test", body: { field: "value2" })

    @batch.add(req1)
    assert_equal 1, @batch.requests.count

    @batch.add(req2)
    assert_equal 2, @batch.requests.count
  end

  def test_add_array_of_requests
    req1 = Parse::Request.new(:post, "/classes/Test", body: { field: "value1" })
    req2 = Parse::Request.new(:post, "/classes/Test", body: { field: "value2" })

    @batch.add([req1, req2])
    assert_equal 2, @batch.requests.count
  end

  def test_add_batch_operation
    req1 = Parse::Request.new(:post, "/classes/Test", body: { field: "value1" })
    req2 = Parse::Request.new(:post, "/classes/Test", body: { field: "value2" })

    other_batch = Parse::BatchOperation.new([req1, req2])
    @batch.add(other_batch)

    assert_equal 2, @batch.requests.count
  end

  def test_clear!
    req = Parse::Request.new(:post, "/classes/Test", body: { field: "value" })
    @batch.add(req)

    assert_equal 1, @batch.requests.count
    @batch.clear!
    assert_empty @batch.requests
  end

  def test_count
    req1 = Parse::Request.new(:post, "/classes/Test", body: { field: "value1" })
    req2 = Parse::Request.new(:post, "/classes/Test", body: { field: "value2" })

    assert_equal 0, @batch.count
    @batch.add(req1)
    assert_equal 1, @batch.count
    @batch.add(req2)
    assert_equal 2, @batch.count
  end

  def test_enumerable
    req1 = Parse::Request.new(:post, "/classes/Test", body: { field: "value1" })
    req2 = Parse::Request.new(:post, "/classes/Test", body: { field: "value2" })

    @batch.add([req1, req2])

    # Test enumerable methods
    assert_respond_to @batch, :each
    assert_respond_to @batch, :map
    assert_respond_to @batch, :select

    # Test iteration
    count = 0
    @batch.each { |r| count += 1 }
    assert_equal 2, count
  end

  def test_success_with_no_responses
    assert_equal false, @batch.success?
  end

  def test_error_with_no_responses
    assert_equal false, @batch.error?
  end
end
