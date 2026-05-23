require_relative "../../test_helper_integration"

# Integration regression test for the 4.0.0 REST path encoding helpers.
# `Parse::API::PathSegment.identifier!` and `.file!` validate names BEFORE
# the request is dispatched to Parse Server. The goal of this test is to
# confirm two things end-to-end:
#
# 1. **No regression on legitimate names.** Function/job/class names that
#    match the documented Parse naming rules pass validation and reach the
#    server. They may fail there for unrelated reasons ("function not
#    registered", "class doesn't exist") but the failure must come from
#    Parse Server, not from our validator.
#
# 2. **Traversal attempts are refused without hitting the server.** A
#    caller passing `"../classes/_User?where={}"` (the exact attack from
#    the security audit's E3 finding) must get an `ArgumentError` back
#    from the SDK before any HTTP request is dispatched. We verify this
#    by ensuring the resulting error is `ArgumentError` rather than any
#    server-side error class — server-side errors would only occur if the
#    bad path actually reached the server.
class PathSegmentIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def with_timeout(seconds, message = "Operation")
    Timeout::timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{message} timed out after #{seconds} seconds"
  end

  # --- 1. Legitimate names reach the server ---

  def test_legitimate_function_name_reaches_server
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "legitimate function name test") do
        puts "\n=== Testing PathSegment: legitimate function name reaches Parse Server ==="

        # A function name that obeys the identifier pattern. The function
        # is not registered on the test Parse Server, so we expect a
        # CloudCodeError (function not found) back — NOT an ArgumentError
        # from the SDK. That distinction is what proves the request got
        # past our validator.
        err = assert_raises do
          Parse.call_function!("notRegisteredFunction", {})
        end

        refute_instance_of ArgumentError, err,
          "Legitimate function name should not be rejected by PathSegment validator. " \
          "Got: #{err.class}: #{err.message}"

        puts "Legitimate function name reached Parse Server (got #{err.class})"
      end
    end
  end

  def test_legitimate_class_name_for_schema_query
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "legitimate class name schema test") do
        puts "\n=== Testing PathSegment: legitimate class name reaches schema endpoint ==="

        # Build a class with a normal identifier-shape name, query its schema.
        # A request that gets past the validator may legitimately come back
        # with a schema or a "class not found" — either way, the SDK accepted
        # the name and dispatched the HTTP request.
        client = Parse::Client.client
        response = client.schema("PartialFetchPost")
        refute_nil response, "schema() must return a Parse::Response"

        # Schema lookup on _User (leading underscore) — must NOT be refused
        # by the identifier validator, since `_User` is the Parse system
        # class naming convention.
        user_schema = client.schema("_User")
        refute_nil user_schema, "_User schema lookup must reach the server"

        puts "Class names 'PartialFetchPost' and '_User' both reached the schema endpoint"
      end
    end
  end

  def test_legitimate_file_name_reaches_server
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "legitimate file name test") do
        puts "\n=== Testing PathSegment: legitimate file name reaches Parse Server ==="

        # A file name with dots and underscores (the file! validator should
        # accept these and percent-encode safely). We don't care if the
        # upload succeeds — just that the validator lets it through.
        client = Parse::Client.client
        begin
          client.create_file("test_image.jpg", "fake-bytes", "image/jpeg")
          puts "File upload succeeded (or got past validator)"
        rescue ArgumentError => e
          flunk "Legitimate file name 'test_image.jpg' was rejected by PathSegment.file!: #{e.message}"
        rescue StandardError => e
          # Any non-ArgumentError is fine — it means the SDK dispatched the
          # request and Parse Server / Faraday returned the response.
          puts "Legitimate file name reached server (got #{e.class}: #{e.message[0..60]})"
        end
      end
    end
  end

  # --- 2. Traversal attempts are refused before any request ---

  def test_function_name_traversal_attempt_refused_locally
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(5, "function traversal refusal test") do
        puts "\n=== Testing PathSegment: traversal attempt refused locally ==="

        attack = "../classes/_User?where=%7B%7D&limit=1000"

        err = assert_raises(ArgumentError) do
          Parse.call_function(attack, {}, opts: { master_key: true })
        end

        assert_match(/function name/, err.message,
          "Refusal error should identify the offending parameter, got: #{err.message}")

        # If the validator had allowed this through, Parse Server would have
        # returned either a 404 (NotFound) or — much worse — a 200 with the
        # full _User collection contents in the response body. The absence
        # of any such response is the assertion this test makes.

        puts "Traversal attempt refused locally with ArgumentError (no HTTP dispatched)"
      end
    end
  end

  def test_class_name_traversal_attempt_refused_locally
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(5, "class name traversal refusal test") do
        puts "\n=== Testing PathSegment: class name traversal refused locally ==="

        client = Parse::Client.client

        # Each of these would, without validation, traverse out of the
        # schemas/ namespace.
        ["../config", "Class.With.Dots", "Class/with/slash", "Class With Space"].each do |attack|
          err = assert_raises(ArgumentError) do
            client.schema(attack)
          end
          assert_match(/class name/, err.message,
            "Refusal for #{attack.inspect} should identify the offending parameter")
        end

        puts "Class name traversal attempts all refused locally"
      end
    end
  end

  def test_file_name_traversal_attempt_refused_locally
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(5, "file traversal refusal test") do
        puts "\n=== Testing PathSegment: file name traversal refused locally ==="

        client = Parse::Client.client

        ["../etc/passwd", "path/to/file.jpg", "..", "name\x00.jpg"].each do |attack|
          err = assert_raises(ArgumentError) do
            client.create_file(attack, "data", "text/plain")
          end
          assert_match(/file name|path-traversal|control characters/, err.message,
            "Refusal for #{attack.inspect} should identify the issue")
        end

        puts "File name traversal attempts all refused locally"
      end
    end
  end
end
