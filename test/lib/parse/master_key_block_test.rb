# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/client/authentication"

# Unit tests for {Parse.with_master_key} / {Parse.without_master_key}
# block helpers and their interaction with the authentication
# middleware. These do not require a running Parse Server.
class TestMasterKeyBlock < Minitest::Test
  # Minimal stand-in for a Faraday response — the middleware chains
  # `@app.call(env).on_complete { ... }`; we just need a sink for that
  # callback in unit-test scope.
  class FakeResponse
    def on_complete(&_blk); self; end
  end

  def fake_env(headers: {})
    { request_headers: headers.dup }
  end

  def build_middleware(master_key: "mk-test")
    inner = ->(_env) { FakeResponse.new }
    mw = Parse::Middleware::Authentication.new(inner,
                                               application_id: "app-id",
                                               api_key: "api",
                                               master_key: master_key)
    mw.application_id = "app-id"
    mw.master_key     = master_key
    mw
  end

  def assert_master_key_attached(headers)
    assert_equal "mk-test", headers[Parse::Protocol::MASTER_KEY],
                 "master key header should be attached"
  end

  def refute_master_key_attached(headers)
    refute headers.key?(Parse::Protocol::MASTER_KEY),
           "master key header should NOT be attached, got #{headers[Parse::Protocol::MASTER_KEY].inspect}"
  end

  def test_default_outside_block_attaches_master_key
    refute Parse.master_key_disabled?
    env = fake_env
    build_middleware.call(env)
    assert_master_key_attached(env[:request_headers])
  end

  def test_without_master_key_block_suppresses_header
    Parse.without_master_key do
      assert Parse.master_key_disabled?
      env = fake_env
      build_middleware.call(env)
      refute_master_key_attached(env[:request_headers])
    end
    refute Parse.master_key_disabled?, "fiber-local state must be restored on exit"
  end

  def test_with_master_key_inside_without_master_key_reenables
    Parse.without_master_key do
      Parse.with_master_key do
        refute Parse.master_key_disabled?
        env = fake_env
        build_middleware.call(env)
        assert_master_key_attached(env[:request_headers])
      end
      assert Parse.master_key_disabled?
      env = fake_env
      build_middleware.call(env)
      refute_master_key_attached(env[:request_headers])
    end
  end

  def test_without_master_key_restores_state_on_exception
    begin
      Parse.without_master_key do
        raise "boom"
      end
    rescue RuntimeError => e
      assert_equal "boom", e.message
    end
    refute Parse.master_key_disabled?
  end

  def test_per_request_disable_header_still_suppresses
    env = fake_env(headers: { Parse::Middleware::Authentication::DISABLE_MASTER_KEY => "1" })
    build_middleware.call(env)
    refute_master_key_attached(env[:request_headers])
    refute env[:request_headers].key?(Parse::Middleware::Authentication::DISABLE_MASTER_KEY)
  end

  def test_fiber_local_state_survives_after_per_request_header_stripped
    # Per-request header is removed on first call; fiber-local state
    # remains the source of truth on Faraday retry.
    Parse.without_master_key do
      env = fake_env(headers: { Parse::Middleware::Authentication::DISABLE_MASTER_KEY => "1" })
      build_middleware.call(env)
      refute_master_key_attached(env[:request_headers])
      refute env[:request_headers].key?(Parse::Middleware::Authentication::DISABLE_MASTER_KEY)

      retry_env = fake_env
      build_middleware.call(retry_env)
      refute_master_key_attached(retry_env[:request_headers])
    end
  end

  def test_session_token_still_takes_precedence_over_master_key
    env = fake_env(headers: { Parse::Protocol::SESSION_TOKEN => "r:tok" })
    build_middleware.call(env)
    refute_master_key_attached(env[:request_headers])
  end

  def test_blank_master_key_means_no_header_regardless_of_block
    mw = build_middleware(master_key: nil)
    env = fake_env
    mw.call(env)
    refute_master_key_attached(env[:request_headers])

    Parse.with_master_key do
      env2 = fake_env
      mw.call(env2)
      refute env2[:request_headers].key?(Parse::Protocol::MASTER_KEY),
             "with_master_key does not synthesise a missing master key"
    end
  end
end
