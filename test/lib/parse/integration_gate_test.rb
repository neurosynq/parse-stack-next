# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../support/integration_gate"
require "socket"

# Unit tests for the integration release gate: which skips count as missing
# coverage, and how Parse Server health is probed.
class IntegrationGateTest < Minitest::Test
  G = Parse::Test::IntegrationGate

  def test_service_unreachable_skips_are_infrastructure
    [
      "Parse Server not available: Connection refused",
      "Parse Server unavailable",
      "Docker containers not running",
      "MongoDB unavailable: Mongo::Error::NoServerAvailable: timed out",
      "mongo unavailable",
      "Redis not reachable at redis://localhost:29379/0",
      "Failed to open TCP connection (ECONNREFUSED)",
    ].each { |reason| assert G.infra_skip?(reason), reason }
  end

  def test_legitimate_skips_are_not_infrastructure
    [
      "Atlas Search not reachable at mongodb://localhost:29020. Start it with docker-compose",
      "Atlas-only assertion",
      "set VOYAGE_CONTRACT_KEY to run live Voyage contract tests",
      "openai/anthropic require LLM_API_KEY",
      "Set LLM_PROVIDER (lmstudio | openai | anthropic) to run",
      "ffmpeg not available",
      "rotp gem not available",
      "MongoDB direct tests require mongo gem",
      "timing-sensitive; skipped on macOS CI",
      "snapshot updated: vector_search/master",
      "Server does not support protectedFields CLP configuration",
    ].each { |reason| refute G.infra_skip?(reason), reason }
  end

  def test_infra_skips_parses_skip_log_lines
    lines = [
      "test/a_test.rb\tA#test_one\tParse Server not available\n",
      "test/a_test.rb\tA#test_two\tAtlas-only assertion\n",
      "test/b_test.rb\tB#test_three\tRedis not reachable at redis://x\n",
    ]
    assert_equal [["A#test_one", "Parse Server not available"],
                  ["B#test_three", "Redis not reachable at redis://x"]], G.infra_skips(lines)
  end

  def test_server_healthy_false_when_nothing_listens
    port = TCPServer.open("127.0.0.1", 0) { |s| s.addr[1] } # bound then released
    refute G.server_healthy?("http://127.0.0.1:#{port}/parse", attempts: 1, wait: 0, timeout: 1)
  end

  def test_server_healthy_true_on_200
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new do
      client = server.accept
      client.readpartial(4096)
      client.write("HTTP/1.1 200 OK\r\nContent-Length: 15\r\nConnection: close\r\n\r\n{\"status\":\"ok\"}")
      client.close
    end
    assert G.server_healthy?("http://127.0.0.1:#{port}/parse", attempts: 1, wait: 0, timeout: 2)
  ensure
    thread&.join(2)
    server&.close
  end
end
