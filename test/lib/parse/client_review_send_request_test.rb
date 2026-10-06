# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/client/authentication"

# `Parse::Client#send_request` used to call `request(req)` without the
# request's own options, so a `Parse::Request` carrying `session_token:` and
# `use_master_key: false` still went out with the configured master key.
class ClientReviewSendRequestTest < Minitest::Test
  include Parse::Protocol
  MASTER = "configured-master-key"

  class FakeConn
    attr_reader :calls

    def initialize; @calls = []; end

    def send(method, uri, params, headers)
      @calls << { method: method, uri: uri, headers: headers.dup }
      body = Parse::Response.new({})
      body.http_status = 200
      Struct.new(:body).new(body)
    end
  end

  class FakeResponse
    def on_complete; yield(nil) if block_given?; self; end
  end

  def setup
    @client = Parse::Client.new(
      server_url: "http://localhost:1337/parse",
      app_id: "test-app", api_key: "test-rest",
      master_key: MASTER, logging: false,
    )
    @conn = FakeConn.new
    @client.instance_variable_set(:@conn, @conn)
  end

  # Headers as they go on the wire, after the real Authentication middleware.
  def wire_headers
    produced = @conn.calls.last[:headers]
    final = nil
    terminal = lambda do |env|
      final = env[:request_headers]
      FakeResponse.new
    end
    Parse::Middleware::Authentication.new(
      terminal, application_id: "test-app", api_key: "test-rest", master_key: MASTER,
    ).call({ request_headers: produced.dup })
    final
  end

  def test_session_token_and_master_key_opt_out_are_honored
    req = Parse::Request.new(:get, "classes/Post",
                             opts: { session_token: "r:user-token", use_master_key: false })
    @client.send_request(req)
    wire = wire_headers
    refute wire.key?(MASTER_KEY), "the master key must not be sent for a session request"
    assert_equal "r:user-token", wire[SESSION_TOKEN]
  end

  def test_master_key_opt_out_alone_is_honored
    req = Parse::Request.new(:get, "classes/Post", opts: { use_master_key: false })
    @client.send_request(req)
    refute wire_headers.key?(MASTER_KEY)
  end

  def test_cache_option_is_forwarded
    req = Parse::Request.new(:get, "classes/Post", opts: { cache: false })
    @client.send_request(req)
    assert_equal "no-cache", @conn.calls.last[:headers][Parse::Middleware::Caching::CACHE_CONTROL]
  end

  def test_request_object_passed_to_request_directly_is_honored
    req = Parse::Request.new(:get, "classes/Post",
                             opts: { session_token: "r:user-token", use_master_key: false })
    @client.request(req)
    refute wire_headers.key?(MASTER_KEY)
  end

  def test_explicit_call_opts_win_over_request_opts
    req = Parse::Request.new(:get, "classes/Post", opts: { use_master_key: false })
    @client.request(req, opts: { use_master_key: true })
    assert_equal MASTER, wire_headers[MASTER_KEY]
  end

  def test_request_without_opts_still_uses_the_master_key
    @client.send_request(Parse::Request.new(:get, "classes/Post"))
    assert_equal MASTER, wire_headers[MASTER_KEY]
  end

  def test_request_headers_are_still_sent
    req = Parse::Request.new(:get, "classes/Post", headers: { "X-Custom" => "1" })
    @client.send_request(req)
    assert_equal "1", @conn.calls.last[:headers]["X-Custom"]
  end
end
