# frozen_string_literal: true

require "minitest/reporters"

module Parse
  module Test
    # Appends one line per skipped test to the file named by
    # PSNEXT_SKIP_LOG, as `<test file>\t<Class#method>\t<skip message>`.
    #
    # The Rake integration runner reads this log after each file to tell
    # infrastructure skips (Parse Server, MongoDB, or Redis unreachable)
    # from legitimate ones (Atlas-only, missing API keys, ffmpeg). Without
    # it, a server that dies mid-run turns every later test into a skip and
    # the run still reports success.
    class SkipLogReporter < Minitest::Reporters::BaseReporter
      def initialize(path, test_file)
        super()
        @path = path
        @test_file = test_file
      end

      def record(test)
        super
        return unless test.skipped?

        message = test.failure&.message.to_s.gsub(/[\t\r\n]+/, " ")
        # ::File: inside `module Parse`, a bare `File` is Parse::File.
        ::File.open(@path, "a") do |f|
          f.puts [@test_file, "#{test.klass}##{test.name}", message].join("\t")
        end
      rescue StandardError => e
        # Never let skip logging break a test run.
        $stderr.puts "SKIPLOG-ERR #{e.class}: #{e.message}" if ENV["PSNEXT_SKIP_LOG_DEBUG"]
        nil
      end
    end
  end
end
