require_relative "../../test_helper"

# Unit coverage for retry and idempotency correctness in Parse::Client:
# gateway 5xx without a Parse error body, the server-dedup route whitelist,
# request-id path exclusions, the create-lock lease, replays that would turn
# an applied write into a reported failure, `retry: 0`, and caller header
# hashes that must not be mutated.
class RetryAuditTest < Minitest::Test
  def teardown
    Parse::Request.assume_server_idempotency = false
  end

  # A client whose connection returns the queued responses in order (the
  # last one repeats) and records each attempt's path and headers.
  def stub_client(*responses, retry_limit: 2)
    client = Parse::Client.allocate
    client.instance_variable_set(:@retry_limit, retry_limit)
    client.define_singleton_method(:sleep) { |_s = 0| 0 }
    attempts = []
    queue = responses.dup
    conn = Object.new
    conn.define_singleton_method(:url_prefix) { URI("http://localhost:1/parse/") }
    [:get, :post, :put, :delete].each do |verb|
      conn.define_singleton_method(verb) do |uri, _params, headers|
        attempts << { verb: verb, uri: uri, headers: headers.dup }
        resp = queue.size > 1 ? queue.shift : queue.first
        Struct.new(:body).new(resp.dup)
      end
    end
    client.instance_variable_set(:@conn, conn)
    [client, attempts]
  end

  def response(status, code: nil, error: nil, body: nil)
    r = Parse::Response.new(body || {})
    r.http_status = status
    r.code = code
    r.error = error
    r
  end

  # A Faraday stack with only the BodyBuilder middleware over a test adapter.
  def body_builder_conn(status, body, content_type: "application/json")
    stubs = Faraday::Adapter::Test::Stubs.new
    stubs.post("/parse/x") { [status, { "Content-Type" => content_type }, body] }
    Faraday.new(url: "http://localhost:1/parse") do |c|
      c.use Parse::Middleware::BodyBuilder
      c.adapter :test, stubs
    end
  end

  # --- R3: non-2xx without a Parse error -----------------------------------

  def test_gateway_504_json_without_code_is_an_error
    r = body_builder_conn(504, '{"message":"Endpoint request timed out"}').post("x", {}).body
    assert r.error?
    assert_equal 504, r.code
    assert_includes r.error, "Endpoint request timed out"
  end

  def test_parse_server_message_body_keeps_its_code
    r = body_builder_conn(500, '{"code":1,"message":"Internal server error."}').post("x", {}).body
    assert r.error?
    assert_equal 1, r.code
    assert_equal "Internal server error.", r.error
  end

  def test_2xx_body_with_code_and_error_columns_is_success
    r = body_builder_conn(201, '{"objectId":"a","code":"SKU","error":"none"}').post("x", {}).body
    assert r.success?
    assert_equal "SKU", r.result["code"]
  end

  def test_502_and_504_raise_service_unavailable_and_retry_only_when_idempotent
    [502, 504].each do |status|
      client, attempts = stub_client(response(status, code: status, error: "gateway"))
      assert_raises(Parse::Error::ServiceUnavailableError) { client.request(:post, "classes/Post", body: { a: 1 }) }
      assert_equal 1, attempts.size, "POST must not be replayed after #{status}"

      client, attempts = stub_client(response(status, code: status, error: "gateway"))
      assert_raises(Parse::Error::ServiceUnavailableError) { client.request(:get, "classes/Post") }
      assert_equal 3, attempts.size, "GET is retried after #{status}"
    end
  end

  # --- R4: server dedup only on routes Parse Server dedupes ----------------

  def test_assume_server_idempotency_never_replays_batch
    Parse::Request.assume_server_idempotency = true
    client, attempts = stub_client(response(503, code: 1, error: "x"))
    assert_raises(Parse::Error::ServiceUnavailableError) do
      client.request(:post, "batch", body: { requests: [] }, headers: { "X-Parse-Request-Id" => "rid-1" })
    end
    assert_equal 1, attempts.size
  end

  def test_assume_server_idempotency_replays_whitelisted_routes
    Parse::Request.assume_server_idempotency = true
    ["classes/Post", "/parse/classes/Post", "users", "installations", "functions/doIt", "jobs/run"].each do |path|
      client, attempts = stub_client(response(503, code: 1, error: "x"))
      assert_raises(Parse::Error::ServiceUnavailableError) do
        client.request(:post, path, body: { a: 1 }, headers: { "X-Parse-Request-Id" => "rid-#{path}" })
      end
      assert_equal 3, attempts.size, "#{path} is deduplicated by Parse Server and may be replayed"
      assert_equal ["rid-#{path}"], attempts.map { |a| a[:headers]["X-Parse-Request-Id"] }.uniq
    end
  end

  def test_assume_server_idempotency_does_not_cover_other_paths
    Parse::Request.assume_server_idempotency = true
    { post: %w[files/a.txt push login logout batch], put: %w[schemas/Post config] }.each do |verb, paths|
      paths.each do |path|
        client, attempts = stub_client(response(503, code: 1, error: "x"))
        assert_raises(Parse::Error::ServiceUnavailableError) do
          client.request(verb, path, body: { "__op" => "x", "v" => { "__op" => "Increment" } },
                                     headers: { "X-Parse-Request-Id" => "rid" })
        end
        assert_equal 1, attempts.size, "#{verb.upcase} #{path} must not be replayed"
      end
    end
  end

  # --- R5: request-id exclusions match relative paths ------------------------

  def test_relative_special_paths_get_no_request_id
    %w[functions/foo jobs/foo push logout sessions events/x requestPasswordReset].each do |path|
      req = Parse::Request.new(:post, path, body: {})
      assert_nil req.request_id, "#{path} should not get an automatic request id"
    end
    %w[classes/Post classes/push users installations].each do |path|
      req = Parse::Request.new(:post, path, body: {})
      refute_nil req.request_id, "#{path} should get a request id"
    end
  end

  # --- R6: create-lock lease covers the request budget -----------------------

  def test_request_time_budget_counts_every_attempt_and_backoff
    client = Parse::Client.allocate
    conn = Faraday.new(url: "http://localhost:1/parse")
    conn.options.timeout = 10
    conn.options.open_timeout = 2
    client.instance_variable_set(:@conn, conn)
    client.instance_variable_set(:@retry_limit, 2)
    delay = Parse::Client::RETRY_DELAY
    assert_in_delta 12 * 3 + delay * 1.25 + delay * 2 * 1.25, client.request_time_budget, 0.001
  end

  def test_default_ttl_covers_find_and_create
    budget = Struct.new(:request_time_budget)
    assert_equal 100, Parse::CreateLock.default_ttl(budget.new(50.0))
    assert_equal Parse::CreateLock::MAX_TTL, Parse::CreateLock.default_ttl(budget.new(10_000.0))
    assert_equal Parse::CreateLock::DEFAULT_TTL, Parse::CreateLock.default_ttl(budget.new(0.1))
    assert_operator Parse::CreateLock.default_ttl(budget.new(Parse::Client.allocate.tap do |c|
      c.instance_variable_set(:@conn, Faraday.new(url: "http://localhost:1/parse"))
    end.request_time_budget)), :>, 30, "default client timeouts need far more than 3s"
  end

  class LeaseStore
    attr_reader :expires
    def initialize; @data = {}; end
    def create(key, value, expires: nil)
      return false if @data.key?(key)
      @expires = expires
      @data[key] = value
      true
    end
    def key?(key) = @data.key?(key)
    def [](key) = @data[key]
    def delete(key) = @data.delete(key)
  end

  def test_synchronize_uses_default_ttl_unless_given
    store = LeaseStore.new
    previous = Parse.synchronize_create_store
    Parse.synchronize_create_store = store
    Parse::CreateLock.stub(:default_ttl, 77) do
      Parse::CreateLock.synchronize(parse_class: "Post", query_attrs: { slug: "a" }) { :ok }
      assert_equal 77, store.expires
      Parse::CreateLock.synchronize(parse_class: "Post", query_attrs: { slug: "b" }, options: { ttl: 5 }) { :ok }
      assert_equal 5, store.expires
    end
  ensure
    Parse.synchronize_create_store = previous
  end

  # --- R7: replays must not report an applied write as failed -----------------

  def test_replayed_delete_that_finds_object_gone_is_success
    client, attempts = stub_client(
      response(503, code: 1, error: "upstream reset"),
      response(404, code: 101, error: "Object not found."),
    )
    r = client.request(:delete, "classes/Post/abc")
    assert r.success?
    assert_equal 2, attempts.size
  end

  def test_first_attempt_delete_not_found_is_still_an_error
    client, = stub_client(response(404, code: 101, error: "Object not found."))
    r = client.request(:delete, "classes/Post/abc")
    assert r.object_not_found?
  end

  def test_nested_and_top_level_ops_are_not_replayed
    [
      ["schemas/Post", { className: "Post", fields: { title: { __op: "Delete" } } }],
      ["hooks/functions/foo", { __op: "Delete" }],
      ["classes/Post/abc", { tags: [{ "__op" => "AddUnique", "objects" => ["a"] }] }],
    ].each do |path, body|
      client, attempts = stub_client(response(503, code: 1, error: "x"))
      assert_raises(Parse::Error::ServiceUnavailableError) { client.request(:put, path, body: body) }
      assert_equal 1, attempts.size, "PUT #{path} carries an op and must not be replayed"
    end
  end

  def test_code_143_is_not_a_timeout
    client, = stub_client(response(400, code: 143, error: "no function named: foo is defined"))
    r = client.request(:put, "hooks/functions/foo", body: { url: "https://x" })
    assert r.error?
    assert_equal 143, r.code
  end

  def test_code_124_is_still_a_timeout
    client, = stub_client(response(408, code: 124, error: "timeout"))
    assert_raises(Parse::Error::TimeoutError) { client.request(:get, "classes/Post") }
  end

  # --- R8: retry: 0 disables retries -------------------------------------------

  def test_retry_zero_disables_retries
    client, attempts = stub_client(response(503, code: 1, error: "x"))
    assert_raises(Parse::Error::ServiceUnavailableError) do
      client.request(:put, "classes/Post/abc", body: { title: "y" }, opts: { retry: 0 })
    end
    assert_equal 1, attempts.size
  end

  # --- R9: caller headers are not mutated ---------------------------------------

  def test_caller_headers_are_not_mutated_and_ids_do_not_leak
    client, attempts = stub_client(response(200, body: { "objectId" => "a" }))
    shared = {}
    client.request(:post, "classes/Post", body: { a: 1 }, headers: shared)
    client.request(:post, "classes/Post", body: { a: 2 }, headers: shared)
    assert_empty shared, "the caller's headers hash must not be written to"
    ids = attempts.map { |a| a[:headers]["X-Parse-Request-Id"] }
    assert ids.all?(&:present?)
    refute_equal ids[0], ids[1], "each request needs its own request id"
  end

  def test_request_copies_its_headers
    shared = {}
    Parse::Request.new(:post, "classes/Post", body: {}, headers: shared)
    assert_empty shared
  end
end
