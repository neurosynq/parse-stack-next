require_relative "../../test_helper"
require "parse-stack"
require "parse/agent"
require "parse/agent/mcp_client"
require "stringio"

# The sanitizer is only worth anything if the sinks actually call it. These
# cover the paths where untrusted bytes reach a terminal or a log file.
class TestTerminalSafeSinks < Minitest::Test
  ESC = 0x1B.chr
  BEL = 0x07.chr

  # --- Parse::Agent::MCPClient::Result -------------------------------------
  # Evaluating `mcp.ask(...)` in IRB prints this struct, so `to_s`/`inspect`
  # are a direct write of LLM output (conditioned on tenant rows) to the TTY.

  def test_result_to_s_escapes_the_answer
    result = Parse::Agent::MCPClient::Result.new(
      text: "All clear#{ESC}]52;c;cGF5bG9hZA==#{BEL}",
      tool_calls: [],
      transcript: [],
    )

    refute_includes result.to_s, ESC
    refute_includes result.to_s, BEL
    assert_includes result.to_s, "\\e]52;c;"
  end

  def test_result_inspect_escapes_the_answer
    result = Parse::Agent::MCPClient::Result.new(
      text: "hi#{ESC}[2J",
      tool_calls: [],
      transcript: [],
    )

    refute_includes result.inspect, ESC
  end

  def test_result_to_s_escapes_tool_call_names_and_arguments
    result = Parse::Agent::MCPClient::Result.new(
      text: "done",
      tool_calls: [{ name: "query_class", arguments: { where: "title#{ESC}[31m" } }],
      transcript: [],
    )

    refute_includes result.to_s, ESC
    assert_includes result.to_s, "\\e[31m"
  end

  def test_result_text_itself_is_left_untouched
    # Sanitization is a rendering concern. A caller writing to a non-terminal
    # surface still gets the exact bytes the model returned.
    raw = "answer#{ESC}[0m"
    result = Parse::Agent::MCPClient::Result.new(text: raw, tool_calls: [], transcript: [])

    assert_equal raw, result.text
  end

  def test_result_answer_keeps_its_line_breaks
    result = Parse::Agent::MCPClient::Result.new(
      text: "line one\nline two",
      tool_calls: [],
      transcript: [],
    )

    assert_includes result.to_s, "line one\nline two"
  end

  # --- LLM provider failure paths ------------------------------------------
  # An error body is echoed into the exception message, and a malformed success
  # body produces a JSON::ParserError quoting the offending bytes. IRB prints
  # both raw, so the failure path is a terminal sink too.

  def test_llm_http_error_body_is_escaped_in_the_exception
    res = Struct.new(:code, :body).new("500", "upstream said#{ESC}]52;c;cHduCg==#{BEL}")
    client = Parse::Agent::MCPClient.allocate

    err = assert_raises(RuntimeError) { client.send(:parse_llm_response!, res, "LLM call") }

    refute_includes err.message, ESC
    refute_includes err.message, BEL
    assert_includes err.message, "HTTP 500"
    assert_includes err.message, "\\e]52;c;"
  end

  def test_llm_error_body_cannot_forge_a_log_line
    res = Struct.new(:code, :body).new("500", "boom\nINFO everything is fine")
    client = Parse::Agent::MCPClient.allocate

    err = assert_raises(RuntimeError) { client.send(:parse_llm_response!, res, "LLM call") }

    refute_includes err.message, "\n"
  end

  def test_unparseable_llm_body_raises_an_escaped_parser_error
    res = Struct.new(:code, :body).new("200", "not json#{ESC}[2J")
    client = Parse::Agent::MCPClient.allocate

    err = assert_raises(JSON::ParserError) { client.send(:parse_llm_response!, res, "LLM call") }

    refute_includes err.message, ESC
    assert_includes err.message, "unparseable"
  end

  def test_successful_llm_body_parses_normally
    res = Struct.new(:code, :body).new("200", '{"choices":[]}')
    client = Parse::Agent::MCPClient.allocate

    assert_equal({ "choices" => [] }, client.send(:parse_llm_response!, res, "LLM call"))
  end

  # --- Parse::Middleware::Logging ------------------------------------------

  def test_error_summary_escapes_control_characters_and_newlines
    middleware = Parse::Middleware::Logging.new(->(env) { env })
    env = { status: 400, body: { "error" => "bad#{ESC}[2J\nINFO all clear" } }

    summary = middleware.send(:error_summary, env)

    refute_includes summary, ESC
    refute_includes summary, "\n"
    assert_includes summary, "\\e[2J"
    assert_includes summary, "\\n"
  end

  # --- The legacy `Parse.logging = true` printer ----------------------------
  # This is a separate code path from the Faraday logging middleware and prints
  # straight to stdout, so it needs the same handling.

  def test_legacy_logging_printer_escapes_request_and_response
    previous = Parse::Middleware::BodyBuilder.logging
    begin
      Parse::Middleware::BodyBuilder.logging = true
      env = Faraday::Env.new
      env.method = :post
      env.url = URI("https://example.com/parse/classes/Post")
      env.request_headers = { "X-Custom" => "v#{ESC}[2J" }
      env.body = %({"title":"pwn#{ESC}]52;c;cHduCg==#{BEL}"})

      inner = lambda do |e|
        e.status = 200
        e.body = %({"results":[{"title":"pwn#{ESC}[2J"}]})
        e.response_headers = {}
        Faraday::Response.new(e).tap { |r| r.finish(e) unless r.finished? }
      end

      out, _err = capture_io do
        Parse::Middleware::BodyBuilder.new(inner).call(env)
      end

      refute_includes out, ESC
      refute_includes out, BEL
      assert_includes out, "\\e[2J"
    ensure
      Parse::Middleware::BodyBuilder.logging = previous
    end
  end

  # --- Parse::Client#_safe_warn --------------------------------------------

  def test_safe_warn_escapes_the_server_error_text
    io = StringIO.new
    previous_logger = Parse::Middleware::Logging.current_logger
    begin
      logger = Logger.new(io)
      logger.formatter = ->(_sev, _time, _prog, msg) { "#{msg}\n" }
      Parse::Middleware::Logging.logger = logger

      response = Parse::Response.new
      response.code = 141
      response.error = "handler failed#{ESC}[2J\nINFO all clear"
      response.http_status = 400
      response.request = "POST /functions/doThing"

      Parse::Client._safe_warn("ScriptError", response)

      output = io.string
      refute_includes output, ESC
      assert_includes output, "\\e[2J"
      assert_equal 1, output.lines.size
    ensure
      Parse::Middleware::Logging.logger = previous_logger
    end
  end

  def test_logged_body_is_escaped_and_stays_on_one_line
    io = StringIO.new
    previous_logger = Parse::Middleware::Logging.current_logger
    previous_level = Parse::Middleware::Logging.current_log_level
    begin
      logger = Logger.new(io)
      logger.formatter = ->(_sev, _time, _prog, msg) { "#{msg}\n" }
      Parse::Middleware::Logging.logger = logger
      Parse::Middleware::Logging.log_level = :debug

      middleware = Parse::Middleware::Logging.new(->(env) { env })
      middleware.send(:log_body, %({"title":"pwn#{ESC}[2J\nforged"}), "Response")

      output = io.string
      refute_includes output, ESC
      assert_includes output, "\\e[2J"
      assert_equal 1, output.lines.size
    ensure
      Parse::Middleware::Logging.logger = previous_logger
      Parse::Middleware::Logging.log_level = previous_level
    end
  end
end
