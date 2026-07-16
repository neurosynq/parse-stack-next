# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "open3"
require "tmpdir"

# SEC-20: the shipped `parse-console --url` loader must NOT pass its
# user-supplied argument to bare Kernel#open, which executes `|command`
# strings as a subprocess. It must parse an explicit URI, require an
# HTTP(S) scheme, and only then fetch via open-uri.
class ParseConsoleUrlInjectionTest < Minitest::Test
  BIN = File.expand_path("../../../bin/parse-console", __dir__)
  LIB = File.expand_path("../../../lib", __dir__)

  # Source-level guard: the dangerous pattern must be gone and the safe one
  # present. Stable across CI environments (no subprocess boot needed).
  def test_loader_does_not_use_kernel_open
    src = File.read(BIN)
    refute_match(/JSON\.load\s+open\(/, src,
                 "must not pass --url to bare Kernel#open (SEC-20 command execution)")
    assert_match(/URI\.parse/, src, "must parse the URL before opening it")
    assert_match(/URI::HTTP/, src, "must require an HTTP(S) scheme")
  end

  # Behavioral proof: a `|command` URL must not spawn a subprocess. Runs the
  # real bin; skips if the child can't boot its dependencies in this env
  # (rather than passing for the wrong reason).
  def test_pipe_url_does_not_execute_a_subprocess
    sentinel = File.join(Dir.tmpdir, "psnext_sec20_#{Process.pid}_#{rand(1 << 30)}")
    File.delete(sentinel) if File.exist?(sentinel)
    out, _status = Open3.capture2e(
      RbConfig.ruby, "-I#{LIB}", BIN, "--url", "|touch #{sentinel}"
    )
    if out =~ /cannot load such file|LoadError|Bundler/
      skip "parse-console dependencies not resolvable in this subprocess env: #{out.lines.first}"
    end
    refute File.exist?(sentinel),
           "parse-console --url '|cmd' must not execute the command (SEC-20). Output: #{out}"
    assert_match(/non-HTTP\(S\)|Invalid JSON format .*URI|bad URI/i, out,
                 "the loader should reject the URL at the scheme/parse step, not run it")
  ensure
    File.delete(sentinel) if sentinel && File.exist?(sentinel)
  end
end
