# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "faraday"
require "json"

# Unit tests for Parse::Middleware::BodyBuilder's long-URL GET→POST override.
#
# Parse Server's REST surface caps a GET URL at ~2KB, so for a query whose
# encoded URL exceeds MAX_URL_LENGTH the SDK rewrites the request to a POST
# carrying `_method=GET` and moves the query into the request body.
#
# The two endpoints need DIFFERENT body encodings:
#
#   * find / classes: Parse Server JSON-decodes a string `where` body param,
#     so the historical `application/x-www-form-urlencoded` body
#     (`_method=GET&where=<json>&...`) works.
#   * aggregate: Parse Server's AggregateRouter.getPipeline does NOT JSON-decode
#     a body `pipeline` param. A urlencoded string `pipeline` is mis-read
#     character-by-character ("Invalid aggregate stage '0'"). The override must
#     send a JSON body so the pipeline survives as a real Array.
#
# These tests drive BodyBuilder with a Faraday test adapter and assert the
# converted method / headers / body without needing a live Parse Server.
class BodyBuilderMethodOverrideTest < Minitest::Test
  MAX = Parse::Middleware::BodyBuilder::MAX_URL_LENGTH

  # Build a connection whose adapter snapshots the REQUEST as BodyBuilder
  # hands it to the adapter. We snapshot (not just hold the env reference)
  # because Faraday mutates env.body to the *response* body on completion.
  def capture_env
    captured = nil
    conn = Faraday.new(url: "http://example.test/parse") do |c|
      c.use Parse::Middleware::BodyBuilder
      c.adapter :test do |stub|
        handler = lambda do |env|
          captured = {
            method: env.method,
            body: (env.body && env.body.dup),
            request_headers: env.request_headers.dup,
            query: env.url.query,
          }
          [200, { "Content-Type" => "application/json" }, '{"results":[]}']
        end
        stub.get(/.*/, &handler)
        stub.post(/.*/, &handler)
      end
    end
    yield conn
    captured
  end

  # A pipeline whose JSON is long enough to push the encoded URL past MAX.
  def long_pipeline
    big_in = (0...400).map { |i| "Project$#{format('%010d', i)}" }
    [
      { "$match" => { "_p_project" => { "$in" => big_in } } },
      { "$group" => { "_id" => { "year" => { "$year" => "$createdAt" } }, "count" => { "$sum" => 1 } } },
      { "$sort" => { "_id" => 1 } },
      { "$project" => { "_id" => 0, "objectId" => "$_id", "count" => 1 } },
    ]
  end

  # A `where` whose encoded URL definitely exceeds MAX_URL_LENGTH.
  def long_where
    { "tags" => { "$in" => (0...1200).to_a } }
  end

  # ---- aggregate endpoint: JSON body, pipeline preserved as an Array --------

  def test_long_aggregate_get_becomes_post_with_json_body
    pipeline = long_pipeline
    env = capture_env do |conn|
      conn.get("aggregate/Note", { pipeline: pipeline.to_json })
    end

    assert_equal :post, env[:method], "long aggregate GET must be rewritten to POST"
    assert_equal "GET", env[:request_headers]["X-Http-Method-Override"]
    assert_equal Parse::Protocol::CONTENT_TYPE_FORMAT,
                 env[:request_headers]["Content-Type"],
                 "aggregate override must send a JSON body, not urlencoded"
    assert_nil env[:query], "query must be moved out of the URL"

    body = JSON.parse(env[:body])
    assert_equal "GET", body["_method"], "Parse Server routes the POST to its GET-only handler via _method"
    assert_kind_of Array, body["pipeline"],
                   "pipeline must arrive as a real Array (string form triggers 'Invalid aggregate stage 0')"
    assert_equal pipeline, body["pipeline"], "pipeline content must round-trip unchanged"
  end

  def test_long_aggregate_override_decodes_boolean_params
    # rawValues / rawFieldNames are sent as booleans; Parse Server ignores them
    # unless typeof === 'boolean', so the JSON body must preserve the boolean.
    env = capture_env do |conn|
      conn.get("aggregate/Note", { pipeline: long_pipeline.to_json, rawValues: true })
    end
    body = JSON.parse(env[:body])
    assert_equal true, body["rawValues"], "boolean query params must round-trip as booleans, not strings"
  end

  # ---- non-aggregate endpoint: unchanged urlencoded override ----------------

  def test_long_find_get_keeps_urlencoded_override
    env = capture_env do |conn|
      conn.get("classes/Note", { where: long_where.to_json })
    end

    assert_equal :post, env[:method], "long find GET must still be rewritten to POST"
    assert_equal "GET", env[:request_headers]["X-Http-Method-Override"]
    assert_equal "application/x-www-form-urlencoded", env[:request_headers]["Content-Type"],
                 "find override must keep its historical urlencoded body"
    assert env[:body].start_with?("_method=GET&"), "find override body must start with _method=GET&"
    assert_includes env[:body], "where=", "where must remain in the urlencoded body"
  end

  # ---- short URLs are untouched (stay GET) ----------------------------------

  def test_short_aggregate_get_stays_get
    env = capture_env do |conn|
      conn.get("aggregate/Note", { pipeline: [{ "$group" => { "_id" => "$x" } }].to_json })
    end
    assert_equal :get, env[:method], "a short aggregate URL must stay a GET"
    refute_nil env[:query], "short GET keeps its query string"
    assert_includes env[:query], "pipeline="
  end

  def test_a_class_named_with_aggregate_substring_is_not_treated_as_aggregate
    # "/classes/aggregateThings" contains "aggregate" but not "/aggregate/",
    # so it must take the urlencoded (find) path, not the JSON path.
    env = capture_env do |conn|
      conn.get("classes/aggregateThings", { where: long_where.to_json })
    end
    assert_equal :post, env[:method]
    assert_equal "application/x-www-form-urlencoded", env[:request_headers]["Content-Type"]
    assert env[:body].start_with?("_method=GET&")
  end

  # ---- robustness: long URL with no query string ----------------------------

  # A >=2KB URL whose length is all path and no query is contrived but
  # reachable; the non-aggregate branch must not crash on `"..." + nil`.
  def test_long_non_aggregate_url_with_no_query_does_not_crash
    long_path = "classes/" + ("A" * (Parse::Middleware::BodyBuilder::MAX_URL_LENGTH + 50))
    env = capture_env do |conn|
      conn.get(long_path) # no params -> nil query
    end
    assert_equal :post, env[:method], "a >=2KB URL must still convert to POST"
    assert_equal "_method=GET&", env[:body],
                 "nil query must coerce to an empty string, not raise TypeError"
  end

  def test_long_aggregate_url_with_no_query_is_safe
    long_path = "aggregate/" + ("A" * (Parse::Middleware::BodyBuilder::MAX_URL_LENGTH + 50))
    env = capture_env do |conn|
      conn.get(long_path)
    end
    assert_equal :post, env[:method]
    assert_equal({ "_method" => "GET" }, JSON.parse(env[:body]),
                 "aggregate branch with no query yields just the _method marker, no crash")
  end

  # ---- a non-JSON query value passes through unchanged -----------------------

  def test_aggregate_override_passes_non_json_value_through_unchanged
    # A bare opaque token is not valid JSON; aggregate_override_body must keep
    # it as the exact string (rescue branch), not nil and not an error.
    env = capture_env do |conn|
      conn.get("aggregate/Note", { pipeline: long_pipeline.to_json, opaque: "r:not-json-token" })
    end
    body = JSON.parse(env[:body])
    assert_equal "r:not-json-token", body["opaque"],
                 "a non-JSON query value must survive verbatim through the rescue path"
    assert_kind_of Array, body["pipeline"], "pipeline still decodes to an Array alongside it"
  end
end
