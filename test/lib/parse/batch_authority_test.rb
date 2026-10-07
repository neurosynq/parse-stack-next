require_relative "../../test_helper"

# A batch is one `POST /batch`, and Parse Server runs every sub-request under
# that call's credentials (it ignores per-sub-request headers). These tests
# pin that a batch keeps each request's authority: a raw request's
# `session_token:` / `use_master_key:` options, and the class client an
# object's requests were built for. Mixed authority is split into separate
# calls for a plain batch and refused, with nothing sent, for a transaction.
class BatchAuthorityDefaultWidget < Parse::Object
  parse_class "BatchAuthorityDefaultWidget"
  property :name, :string
end

class BatchAuthorityBoundWidget < Parse::Object
  parse_class "BatchAuthorityBoundWidget"
  property :name, :string
end

class BatchAuthorityTest < Minitest::Test
  CREATED = "2026-01-01T00:00:00.000Z".freeze

  # Fake clients that record every call. Model classes memoize their client,
  # so the instances are shared across tests.
  def self.fake_client(label)
    Parse::Client.allocate.tap do |c|
      c.instance_variable_set(:@conn, Faraday.new(url: "http://localhost:1/parse"))
      c.instance_variable_set(:@retry_limit, 0)
      c.instance_variable_set(:@application_id, label)
    end
  end

  DEFAULT_CLIENT = fake_client("default-app")
  BOUND_CLIENT = fake_client("bound-app")

  def setup
    @saved_default = Parse::Client.clients[:default]
    Parse::Client.clients[:default] = DEFAULT_CLIENT
    BatchAuthorityDefaultWidget.instance_variable_set(:@client, DEFAULT_CLIENT)
    BatchAuthorityBoundWidget.instance_variable_set(:@client, BOUND_CLIENT)
    @calls = []
    calls = @calls
    [DEFAULT_CLIENT, BOUND_CLIENT].each do |client|
      client.define_singleton_method(:request) do |method, path = nil, body: nil, opts: {}, **_rest|
        calls << { client: self, method: method, path: path, body: body, opts: opts }
        reqs = body["requests"] || body[:requests] || []
        Parse::Response.new(reqs.map do |r|
          name = (r["body"] || r[:body] || {})["name"]
          { "success" => { "objectId" => "ID_#{name}", "createdAt" => CREATED, "updatedAt" => CREATED } }
        end)
      end
    end
  end

  def teardown
    [DEFAULT_CLIENT, BOUND_CLIENT].each do |client|
      client.singleton_class.send(:remove_method, :request) if client.singleton_class.method_defined?(:request)
    end
    if @saved_default
      Parse::Client.clients[:default] = @saved_default
    else
      Parse::Client.clients.delete(:default)
    end
  end

  def calls_on(client)
    @calls.select { |c| c[:client].equal?(client) }
  end

  def sent_requests(call)
    call[:body]["requests"] || call[:body][:requests]
  end

  # A fetched, saved object with a pending change to `name`.
  def saved(klass, id, name)
    klass.build({ "objectId" => id, "name" => "old", "createdAt" => CREATED, "updatedAt" => CREATED }).tap do |o|
      o.name = name
    end
  end

  # Raw requests

  def test_raw_request_session_options_are_sent_with_the_batch
    req = Parse::Request.new(:put, "/parse/classes/X/abc", body: { v: 2 },
                                                          opts: { session_token: "r:user", use_master_key: false })
    Parse.batch([req]).submit
    assert_equal 1, @calls.size
    assert_equal({ session_token: "r:user", use_master_key: false }, @calls.first[:opts])
  end

  def test_requests_without_explicit_authority_send_no_options
    reqs = [Parse::Request.new(:put, "/parse/classes/X/a", body: { v: 1 }),
            Parse::Request.new(:put, "/parse/classes/X/b", body: { v: 2 })]
    Parse.batch(reqs).submit
    assert_equal 1, @calls.size
    assert_equal({}, @calls.first[:opts])
  end

  def test_raw_requests_with_different_sessions_are_split_in_order
    a = Parse::Request.new(:put, "/parse/classes/X/a", body: { "name" => "a" }, opts: { session_token: "r:one" })
    b = Parse::Request.new(:put, "/parse/classes/X/b", body: { "name" => "b" }, opts: { session_token: "r:two" })
    c = Parse::Request.new(:put, "/parse/classes/X/c", body: { "name" => "c" }, opts: { session_token: "r:one" })
    batch = Parse.batch([a, b, c])
    responses = batch.submit
    assert_equal 2, @calls.size
    by_token = @calls.to_h { |call| [call[:opts][:session_token], sent_requests(call).map { |r| r["body"]["name"] }] }
    assert_equal({ "r:one" => %w[a c], "r:two" => %w[b] }, by_token)
    assert_equal %w[ID_a ID_b ID_c], responses.map { |r| r.result["objectId"] }
  end

  # Objects bound to a class client

  def test_array_save_uses_the_objects_class_client
    [saved(BatchAuthorityBoundWidget, "B1", "b1")].save
    assert_empty calls_on(DEFAULT_CLIENT)
    assert_equal 1, calls_on(BOUND_CLIENT).size
  end

  def test_array_destroy_uses_the_objects_class_client
    [BatchAuthorityBoundWidget.new(objectId: "B1")].destroy
    assert_empty calls_on(DEFAULT_CLIENT)
    assert_equal 1, calls_on(BOUND_CLIENT).size
    assert_equal "DELETE", sent_requests(calls_on(BOUND_CLIENT).first).first["method"]
  end

  def test_transaction_uses_the_objects_class_client
    obj = saved(BatchAuthorityBoundWidget, "B1", "b1")
    Parse::Object.transaction { |tx| tx.add(obj) }
    assert_empty calls_on(DEFAULT_CLIENT)
    call = calls_on(BOUND_CLIENT).first
    refute_nil call
    assert_equal true, call[:body]["transaction"] || call[:body][:transaction]
  end

  def test_mixed_client_transaction_raises_and_sends_nothing
    a = saved(BatchAuthorityDefaultWidget, "A1", "a1")
    b = saved(BatchAuthorityBoundWidget, "B1", "b1")
    assert_raises(Parse::BatchOperation::MixedAuthorityError) do
      Parse::Object.transaction do |tx|
        tx.add(a)
        tx.add(b)
      end
    end
    assert_empty @calls
  end

  def test_mixed_session_transaction_raises_and_sends_nothing
    a = Parse::Request.new(:put, "/parse/classes/X/a", body: { v: 1 }, opts: { session_token: "r:one" })
    b = Parse::Request.new(:put, "/parse/classes/X/b", body: { v: 2 })
    batch = Parse::BatchOperation.new([a, b], transaction: true)
    assert_raises(Parse::BatchOperation::MixedAuthorityError) { batch.submit }
    assert_empty @calls
  end

  def test_transaction_on_a_batch_with_another_explicit_client_raises
    obj = saved(BatchAuthorityBoundWidget, "B1", "b1")
    batch = Parse::BatchOperation.new(nil, transaction: true)
    batch.client = DEFAULT_CLIENT
    batch.add(obj)
    assert_raises(Parse::BatchOperation::MixedAuthorityError) { batch.submit }
    assert_empty @calls
  end

  def test_mixed_clients_in_array_save_are_split_and_applied_in_order
    a1 = BatchAuthorityDefaultWidget.new(name: "a1")
    b1 = BatchAuthorityBoundWidget.new(name: "b1")
    a2 = BatchAuthorityDefaultWidget.new(name: "a2")
    [a1, b1, a2].save
    assert_equal 1, calls_on(DEFAULT_CLIENT).size
    assert_equal 1, calls_on(BOUND_CLIENT).size
    assert_equal %w[a1 a2], sent_requests(calls_on(DEFAULT_CLIENT).first).map { |r| r["body"]["name"] }
    assert_equal %w[b1], sent_requests(calls_on(BOUND_CLIENT).first).map { |r| r["body"]["name"] }
    assert_equal %w[ID_a1 ID_b1 ID_a2], [a1, b1, a2].map(&:id)
  end

  # Ambient and default authority are unchanged

  def test_ambient_session_still_applies_to_default_client_batches
    Parse.with_session("r:ambient") { [saved(BatchAuthorityDefaultWidget, "A1", "a1")].save }
    assert_equal 1, @calls.size
    # No explicit options: Parse::Client#request resolves the ambient session.
    assert_equal({}, @calls.first[:opts])
  end

  # Explicit session argument

  def test_session_argument_is_sent_with_every_batch_call
    objs = [saved(BatchAuthorityDefaultWidget, "A1", "a1"), saved(BatchAuthorityBoundWidget, "B1", "b1")]
    objs.save(session: "r:caller")
    assert_equal 2, @calls.size
    assert(@calls.all? { |c| c[:opts][:session_token] == "r:caller" })
  end

  def test_session_argument_on_destroy_and_transaction
    [BatchAuthorityDefaultWidget.new(objectId: "A1")].destroy(session: "r:caller")
    Parse::Object.transaction(session: "r:caller") { |tx| tx.add(saved(BatchAuthorityDefaultWidget, "A2", "a2")) }
    assert_equal 2, @calls.size
    assert(@calls.all? { |c| c[:opts][:session_token] == "r:caller" })
  end

  def test_blank_session_argument_is_refused
    assert_raises(ArgumentError) { [saved(BatchAuthorityDefaultWidget, "A1", "a1")].save(session: "  ") }
    assert_empty @calls
  end
end
