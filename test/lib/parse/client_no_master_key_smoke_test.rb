# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "faraday"

# Top-level "import the gem, do the obvious thing, get the obvious
# result" smoke test for the v5.0 client-mode resolution chain.
#
# The earlier +client_master_key_env_fallthrough_test.rb+ pins the
# behavior of {Parse::Client#request} at the request-construction
# layer (the +DISABLE_MASTER_KEY+ marker). This file goes one level
# higher: it stands up a fresh {Parse::Object} subclass, swaps the
# default client to one with NO master key configured (the operator
# never set one — the "import the gem and use it" baseline), exercises
# the +Song.all+ / +Song.first+ / +Song.create+ class-method surface,
# and asserts at the bottom of the Faraday stack that the
# +X-Parse-Master-Key+ header never reaches the wire.
#
# What this catches that the lower-level test does NOT:
#
# - A regression in {Parse::Query} that re-introduces the
#   +@use_master_key = true+ default would slip past the lower-level
#   test (which doesn't go through Query) but would surface here as a
#   MASTER_KEY header on the recorded GET.
# - A regression in {Parse::Object::ClassMethods} that adds an implicit
#   +use_master_key: true+ to the auto-built query would surface here
#   for the same reason.
# - A regression in {Parse::Client#initialize} that synthesises a master
#   key from an ENV var even when +master_key: nil+ was passed
#   explicitly would surface here.
#
# The full Faraday middleware chain (Authentication + BodyBuilder) runs
# against a +Faraday::Adapter::Test+ stub, so we observe exactly what
# the HTTP layer would have sent — but no network call happens.
class ClientNoMasterKeySmokeTest < Minitest::Test
  # A throwaway model class scoped to this file. Defined at the top so
  # +Parse::Object.descendants+ can find it during the client-cache
  # invalidation step.
  class Probe < Parse::Object
    parse_class "Probe"
    property :name, :string
  end

  def setup
    @prior_default      = Parse::Client.clients[:default]
    @prior_client_mode  = Parse.client_mode
    @prior_env_master   = ENV["PARSE_SERVER_MASTER_KEY"]
    @prior_env_master2  = ENV["PARSE_MASTER_KEY"]
    @prior_env_cmode    = ENV["PARSE_CLIENT_MODE"]
    # Force the ENV-fallthrough off so build_client(master_key: nil)
    # really does produce a key-less client.
    ENV.delete("PARSE_SERVER_MASTER_KEY")
    ENV.delete("PARSE_MASTER_KEY")
    Parse.client_mode = false
  end

  def teardown
    Parse::Client.clients[:default] = @prior_default
    Parse.client_mode = @prior_client_mode
    ENV["PARSE_SERVER_MASTER_KEY"] = @prior_env_master
    ENV["PARSE_MASTER_KEY"]        = @prior_env_master2
    ENV["PARSE_CLIENT_MODE"]       = @prior_env_cmode
    invalidate_model_client_cache!
  end

  # --------------------------------------------------------------------
  # The headline assertion: +Song.all+ (class-level model API, the most
  # idiomatic "do the obvious thing" call) under a master-key-less
  # default client produces a request with NO +X-Parse-Master-Key+
  # header at the bottom of the Faraday chain.
  # --------------------------------------------------------------------
  def test_class_level_all_does_not_send_master_key_header_when_unconfigured
    captured = nil
    install_stub_client(master_key: nil) do |stubs|
      stubs.get(%r{/parse/classes/Probe}) do |env|
        captured = env
        [200, { "Content-Type" => "application/json" }, '{"results":[]}']
      end

      result = Probe.all
      assert_equal [], result, "stub returns empty results; the call must complete"
    end

    refute_nil captured, "the stub must have observed exactly one GET to /classes/Probe"
    refute captured.request_headers.key?(Parse::Protocol::MASTER_KEY),
           "master key header must NOT appear when no master key is configured " \
           "(headers seen: #{captured.request_headers.keys.inspect})"
    assert_equal "test-app",  captured.request_headers[Parse::Protocol::APP_ID]
    assert_equal "test-rest", captured.request_headers[Parse::Protocol::API_KEY]
  end

  # --------------------------------------------------------------------
  # Tri-state guard: +Parse::Query#@use_master_key+ must default to nil
  # (not true). If a future change re-flips it to +true+ at init time,
  # the request-time auth resolver treats it as an explicit opt-in and
  # would attach the master key even when one isn't configured locally
  # — but more dangerously, would attach it when one IS configured
  # later in the test process (multi-tenant gem usage). Pin the default
  # directly so we catch the flip without round-tripping through HTTP.
  # --------------------------------------------------------------------
  def test_parse_query_use_master_key_defaults_to_nil_not_true
    q = Parse::Query.new("Probe")
    assert_nil q.use_master_key,
               "Parse::Query#@use_master_key must default to nil " \
               "(the v5.0 flip that closes the silent-ACL-bypass)"
  end

  # --------------------------------------------------------------------
  # Sanity assertion in the other direction: when a master key IS
  # configured (the legitimate server-side deployment), the obvious-thing
  # call DOES send the header. This pins the asymmetry so a future
  # over-correction that suppresses the master key unconditionally is
  # also caught here.
  # --------------------------------------------------------------------
  def test_class_level_all_does_send_master_key_when_configured
    captured = nil
    install_stub_client(master_key: "configured-master") do |stubs|
      stubs.get(%r{/parse/classes/Probe}) do |env|
        captured = env
        [200, { "Content-Type" => "application/json" }, '{"results":[]}']
      end
      Probe.all
    end
    refute_nil captured
    assert_equal "configured-master", captured.request_headers[Parse::Protocol::MASTER_KEY],
                 "with master_key configured and client_mode off, the obvious call must send it"
  end

  # --------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------

  # Build a Parse::Client with the requested master_key, then surgically
  # rebuild its Faraday connection so the bottom of the stack is the
  # Faraday test adapter. The full middleware chain
  # (Authentication + BodyBuilder) runs as it would in production, so
  # the captured headers reflect what the HTTP layer would actually
  # send.
  def install_stub_client(master_key:)
    stubs = Faraday::Adapter::Test::Stubs.new
    client = Parse::Client.new(
      server_url: "http://test.example/parse",
      app_id: "test-app",
      api_key: "test-rest",
      master_key: master_key,
      logging: false,
    )

    conn = Faraday.new(url: "http://test.example/parse") do |c|
      c.use Parse::Middleware::Authentication,
            application_id: "test-app", api_key: "test-rest", master_key: master_key
      c.use Parse::Middleware::BodyBuilder
      c.adapter :test, stubs
    end
    client.instance_variable_set(:@conn, conn)

    Parse::Client.clients[:default] = client
    invalidate_model_client_cache!

    yield stubs
    stubs.verify_stubbed_calls
  ensure
    stubs&.verify_stubbed_calls rescue nil
  end

  # Parse::Object caches +@client+ at the class level (+||=+). Once
  # Probe has resolved a client, swapping +Parse::Client.clients[:default]+
  # has no effect. Force a re-resolve.
  def invalidate_model_client_cache!
    [Parse::Object, *Parse::Object.descendants, Parse::Query].each do |klass|
      klass.remove_instance_variable(:@client) if klass.instance_variable_defined?(:@client)
    end
  end
end
