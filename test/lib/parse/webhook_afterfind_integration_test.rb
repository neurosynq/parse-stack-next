# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper_integration"
require_relative "../../support/webhook_test_server"

# End-to-end proof that beforeFind/afterFind webhooks route through the real
# HTTP dispatch pipeline:
#
#   Parse Server (Docker) -> HTTP POST afterFind webhook -> in-process WEBrick ->
#   Parse::Webhooks Rack app -> webhook block
#
# This guards the v5.4.0 fix that threads the class name from the webhook URL
# path (`/afterFind/<Class>`) into the Payload. Parse Server's find payload body
# carries NO className anywhere (the matched objects omit it and there is no
# top-level className — verified against Parse Server 9.9.0), so without the
# path-derived class, parse_class was nil and the dispatch never invoked the
# registered find handler, and afterFind `objects` could not have their :vector
# columns stripped.
#
# Requires Docker (PARSE_TEST_USE_DOCKER=true) and a container whose
# host.docker.internal resolves back to the test host.
class WebhookAfterFindPost < Parse::Object
  parse_class "WebhookAfterFindPost"
  acl_policy :public
  property :title, :string
  property :embedding, :vector, dimensions: 3
end

class WebhookAfterFindIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def setup
    super
    Parse::Webhooks.instance_variable_set(:@routes, nil)
    Parse::Webhooks.allow_unauthenticated = true
    @prior_private = Parse::Webhooks.instance_variable_get(:@allow_private_webhook_urls)
    Parse::Webhooks.allow_private_webhook_urls = true
    @server = Parse::Test::WebhookTestServer.new.start!
    unless docker_can_reach_host?
      @server.stop!
      skip "container cannot reach host at #{@server.url}"
    end
  end

  def teardown
    begin
      Parse::Webhooks.remove_all_triggers! if @server
    rescue StandardError
    end
    # Don't let rows accumulate across re-runs / other suites sharing the DB.
    begin
      WebhookAfterFindPost.query.results.each(&:destroy)
    rescue StandardError
    end
    @server&.stop!
    Parse::Webhooks.allow_unauthenticated = false
    Parse::Webhooks.instance_variable_set(:@allow_private_webhook_urls, @prior_private)
    super
  end

  def docker_can_reach_host?
    result = `docker exec #{ENV["PSNEXT_PREFIX"] || "psnext-it"}-server sh -c 'getent hosts host.docker.internal' 2>&1`
    !result.empty? && $?.success?
  end

  def test_after_find_routes_and_scrubs_vectors_end_to_end
    captured = {}
    Parse::Webhooks.route(:after_find, "WebhookAfterFindPost") do
      captured[:fired] = true
      captured[:parse_class] = parse_class
      captured[:count] = objects.size
      captured[:first_keys] = objects.first.is_a?(Hash) ? objects.first.keys.map(&:to_s).sort : nil
      captured[:any_has_embedding] = objects.any? { |o| o.is_a?(Hash) && o.key?("embedding") }
      objects # return the (vector-scrubbed) matched objects
    end
    Parse::Webhooks.register_triggers!(@server.url)

    3.times do |i|
      o = WebhookAfterFindPost.new(title: "p#{i}")
      o.embedding = Parse::Vector.new([1.0 + i, 2.0, 3.0])
      o.save
    end

    query_error = nil
    results = nil
    begin
      results = WebhookAfterFindPost.query.results
    rescue StandardError => e
      query_error = "#{e.class}: #{e.message}"
    end

    assert captured[:fired], "afterFind handler must fire via the real HTTP dispatch (path-derived class)"
    assert_equal "WebhookAfterFindPost", captured[:parse_class],
                 "parse_class must resolve from the webhook URL path for find triggers"
    assert captured[:count].to_i >= 3, "handler must see the matched objects (saw #{captured[:count]})"
    refute captured[:any_has_embedding],
           "afterFind objects must have their :vector column stripped (class resolved from the route)"
    refute_includes (captured[:first_keys] || []), "embedding"
    # Critically: a registered afterFind that fails to route returns
    # `{"success": true}` (not an objects array), which Parse Server rejects and
    # the query EOFs. So a passing query here also proves the routing fix —
    # before it, this raised Faraday::ConnectionFailed.
    assert_nil query_error, "afterFind must not break the query (got #{query_error})"
    assert results.size >= 3, "afterFind must not drop the query results"
  end
end
