# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# A request sent alone and the same request sent in a batch must reach Parse
# Server with the same authentication headers. This drives the real client
# middleware stack against a Faraday test adapter and compares the headers
# the server would see.
class BatchAuthHeadersTest < Minitest::Test
  AUTH_HEADERS = [Parse::Protocol::MASTER_KEY, Parse::Protocol::SESSION_TOKEN].freeze

  def setup
    @seen = []
    seen = @seen
    @stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/parse/batch") do |env|
        seen << env.request_headers.to_h
        body = JSON.parse(env.body)
        [200, { "Content-Type" => "application/json" },
         JSON.generate(body["requests"].map { { "success" => { "updatedAt" => "2026-01-01T00:00:00.000Z" } } })]
      end
      stub.put(%r{/parse/classes/X/.*}) do |env|
        seen << env.request_headers.to_h
        [200, { "Content-Type" => "application/json" }, JSON.generate("updatedAt" => "2026-01-01T00:00:00.000Z")]
      end
    end
    @client = Parse::Client.new(server_url: "http://localhost:1/parse", application_id: "a",
                                api_key: "k", master_key: "mk", connection_pooling: false)
    builder = @client.instance_variable_get(:@conn).builder
    builder.adapter(:test, @stubs)
  end

  def auth_of(headers)
    AUTH_HEADERS.to_h { |h| [h, headers[h]] }
  end

  def compare(request_attrs)
    single = Parse::Request.new(:put, "/parse/classes/X/abc", body: { v: 1 }, **request_attrs)
    batched = Parse::Request.new(:put, "/parse/classes/X/abc", body: { v: 1 }, **request_attrs)
    @client.request(single)
    @client.batch_request([batched])
    assert_equal 2, @seen.size, "expected one single request and one batch call"
    assert_equal auth_of(@seen[0]), auth_of(@seen[1]),
                 "batch auth headers differ from the single request for #{request_attrs.inspect}"
    auth_of(@seen[1])
  end

  def test_suppression_header_with_use_master_key_true_matches_single_request
    auth = compare(headers: { Parse::Middleware::Authentication::DISABLE_MASTER_KEY => "true" },
                   opts: { use_master_key: true })
    assert_nil auth[Parse::Protocol::MASTER_KEY], "the suppression header must keep the master key off"
  end

  def test_header_session_token_matches_single_request
    auth = compare(headers: { Parse::Protocol::SESSION_TOKEN => "r:hdr" })
    assert_equal "r:hdr", auth[Parse::Protocol::SESSION_TOKEN]
    assert_nil auth[Parse::Protocol::MASTER_KEY]
  end

  def test_option_session_token_matches_single_request
    compare(opts: { session_token: "r:opt" })
  end

  def test_use_master_key_false_matches_single_request
    auth = compare(opts: { use_master_key: false })
    assert_nil auth[Parse::Protocol::MASTER_KEY]
  end

  def test_no_explicit_credentials_matches_single_request
    auth = compare({})
    assert_equal "mk", auth[Parse::Protocol::MASTER_KEY]
  end
end
