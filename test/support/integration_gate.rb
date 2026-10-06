# frozen_string_literal: true

require "net/http"
require "uri"

module Parse
  module Test
    # Release-gate checks for the integration runner (`rake test:integration`).
    #
    # Two failure modes used to pass silently:
    #
    # * Parse Server dying mid-run. Later files either errored with
    #   `Faraday::ConnectionFailed` or skipped as "server not available", and
    #   the skips counted as success.
    # * Coverage skipped for infrastructure reasons (Parse Server, MongoDB, or
    #   Redis unreachable) rather than for a legitimate reason (Atlas-only
    #   assertions, missing API keys, ffmpeg not installed).
    #
    # The runner calls {.server_healthy?} before each file and after each
    # failure, and {.infra_skips} on the skip log the test helper writes
    # (PSNEXT_SKIP_LOG, see test/support/skip_log_reporter.rb).
    module IntegrationGate
      module_function

      # Skip reasons that mean a required service was unreachable. A skip for
      # one of these reasons is missing coverage, not an intentional opt-out.
      INFRA_SKIP_PATTERNS = [
        /Parse Server (is )?(not available|unavailable|not reachable|unreachable)/i,
        /Could not connect to Parse Server/i,
        /Docker containers not running/i,
        /\bmongo(db)? (is )?(not reachable|unreachable|unavailable)\b/i,
        /MongoDB unavailable/i,
        /Redis (is )?not reachable/i,
        /Connection refused|ECONNREFUSED/i,
      ].freeze

      # Unambiguous infrastructure failures: always missing coverage in a
      # Docker run, checked BEFORE the legitimate-skip patterns so a message
      # that also mentions credentials or keys is not excused.
      CORE_INFRA_SKIP_PATTERNS = [
        /Parse Server (is )?(not available|unavailable|not reachable|unreachable)/i,
        /Could not connect to Parse Server/i,
        /Docker containers not running/i,
        /Unable to start Docker containers/i,
        /container cannot reach (the )?host/i,
        /needs Parse::MongoDB/i,
      ].freeze

      # Skip reasons that are legitimate even in a full Docker run: the
      # assertion needs a service or credential the standard stack does not
      # provide. Checked first, so "Atlas Search not reachable" stays a
      # legitimate skip even though it mentions reachability.
      LEGIT_SKIP_PATTERNS = [
        /Atlas/i,
        /API_KEY|_KEY\b|CONTRACT_KEY|LLM_PROVIDER|credentials?/i,
        /ffmpeg/i,
        /gem (is )?not available|requires? .*gem/i,
        /timing-sensitive/i,
        /snapshot updated/i,
      ].freeze

      # @param reason [String] a skip message.
      # @return [Boolean] true when the skip means a required service was
      #   unreachable.
      def infra_skip?(reason)
        text = reason.to_s
        return true if CORE_INFRA_SKIP_PATTERNS.any? { |re| re.match?(text) }
        return false if LEGIT_SKIP_PATTERNS.any? { |re| re.match?(text) }
        INFRA_SKIP_PATTERNS.any? { |re| re.match?(text) }
      end

      # @param lines [Array<String>] skip-log lines, `file\ttest\treason`.
      # @return [Array<Array(String, String)>] `[test, reason]` pairs for
      #   infrastructure skips.
      def infra_skips(lines)
        lines.filter_map do |line|
          _file, test, reason = line.chomp.split("\t", 3)
          [test.to_s, reason.to_s] if infra_skip?(reason)
        end
      end

      # @param base_url [String] the Parse Server mount, e.g.
      #   http://localhost:29337/parse.
      # @param attempts [Integer] tries before declaring the server down, so
      #   a momentary blip is not mistaken for a crash.
      # @param wait [Numeric] seconds between tries.
      # @return [Boolean] true when `<base_url>/health` answers 200.
      def server_healthy?(base_url = default_server_url, attempts: 3, wait: 2, timeout: 5)
        uri = URI("#{base_url.to_s.chomp("/")}/health")
        attempts.times do |i|
          begin
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = uri.scheme == "https"
            http.open_timeout = timeout
            http.read_timeout = timeout
            return true if http.request(Net::HTTP::Get.new(uri.request_uri)).code == "200"
          rescue StandardError
            # Treated as unhealthy for this attempt.
          end
          sleep(wait) if i < attempts - 1
        end
        false
      end

      def default_server_url
        ENV["PARSE_TEST_SERVER_URL"] || "http://localhost:29337/parse"
      end
    end
  end
end
