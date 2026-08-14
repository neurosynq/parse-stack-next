require_relative "../../test_helper"
require "parse/terminal_safe"

# Regression coverage for the terminal-escape sanitizer.
#
# The payloads below are written from codepoints rather than as literal escapes
# so this file itself never carries the control bytes it asserts about.
class TestTerminalSafe < Minitest::Test
  T = Parse::TerminalSafe

  ESC = 0x1B.chr
  BEL = 0x07.chr
  CR = 0x0D.chr
  BS = 0x08.chr
  DEL = 0x7F.chr

  def test_osc_52_clipboard_write_is_neutralized
    # OSC 52 asks the terminal to place the payload on the system clipboard,
    # which is the step that turns "display" into "the operator pastes and runs".
    payload = "invoice #{ESC}]52;c;cm0gLXJmIH4=#{BEL} paid"
    out = T.sanitize(payload)

    refute_includes out, ESC
    refute_includes out, BEL
    assert_includes out, "\\e]52;c;"
    assert_includes out, "\\a"
  end

  def test_screen_clearing_csi_is_neutralized
    out = T.sanitize("#{ESC}[2J#{ESC}[H you saw nothing")

    refute_includes out, ESC
    assert_equal "\\e[2J\\e[H you saw nothing", out
  end

  def test_c1_eight_bit_introducers_are_neutralized
    # 0x9B is the 8-bit CSI, 0x9D the 8-bit OSC. A sanitizer that only looks
    # for 0x1B misses both.
    csi = [0x9B].pack("U")
    osc = [0x9D].pack("U")
    out = T.sanitize("#{csi}2J#{osc}0;title#{BEL}")

    refute_includes out, csi
    refute_includes out, osc
    assert_includes out, "\\x9B"
    assert_includes out, "\\x9D"
  end

  def test_carriage_return_overwrite_is_neutralized
    out = T.sanitize("transfer $1.00#{CR}transfer $9,000.00")

    refute_includes out, CR
    assert_includes out, "\\r"
  end

  def test_backspace_and_del_are_neutralized
    out = T.sanitize("safe#{BS}#{BS}#{DEL}evil")

    refute_includes out, BS
    refute_includes out, DEL
    assert_equal "safe\\b\\b\\x7Fevil", out
  end

  def test_bidi_override_is_neutralized
    rlo = [0x202E].pack("U")
    pdf = [0x202C].pack("U")
    out = T.sanitize("report#{rlo}gnp.exe#{pdf}")

    refute_includes out, rlo
    refute_includes out, pdf
    assert_includes out, "\\u202E"
    assert_includes out, "\\u202C"
  end

  def test_zero_width_and_bom_are_neutralized
    out = T.sanitize([0x200B, 0x2060, 0xFEFF].pack("U*"))

    assert_equal "\\u200B\\u2060\\uFEFF", out
  end

  def test_arabic_letter_mark_is_neutralized
    # U+061C is an implicit bidi control and reorders a line exactly like the
    # explicit overrides, but sits outside the U+202x block.
    alm = [0x061C].pack("U")
    out = T.sanitize("total#{alm}reversed")

    refute_includes out, alm
    assert_includes out, "\\u061C"
  end

  def test_unicode_line_separators_are_neutralized
    # U+2028/U+2029 are treated as line breaks by terminals, editors, and log
    # readers, so leaving them intact would reintroduce forged records.
    out = T.sanitize_line("not found#{[0x2028].pack("U")}INFO all clear")

    refute_includes out, [0x2028].pack("U")
    assert_includes out, "\\u2028"
  end

  def test_unicode_paragraph_separator_is_neutralized_in_both_modes
    ps = [0x2029].pack("U")

    refute_includes T.sanitize("a#{ps}b"), ps
    refute_includes T.sanitize_line("a#{ps}b"), ps
  end

  def test_source_file_contains_no_literal_control_characters
    # The sanitizer's own source must not carry the bytes it defends against,
    # or reading the file in a terminal is itself the attack.
    source = File.read(File.expand_path("../../../lib/parse/terminal_safe.rb", __dir__))
    stripped = source.delete("\n\t")

    assert_equal stripped, T.sanitize(stripped)
  end

  def test_newlines_and_tabs_survive_sanitize
    assert_equal "a\nb\tc", T.sanitize("a\nb\tc")
  end

  def test_sanitize_line_escapes_newlines_to_stop_log_forging
    forged = "not found\n2026-08-14 INFO  all clear, nothing to see"
    out = T.sanitize_line(forged)

    refute_includes out, "\n"
    assert_includes out, "\\n"
  end

  def test_sanitize_line_still_allows_tabs
    assert_equal "a\tb", T.sanitize_line("a\tb")
  end

  def test_plain_text_is_returned_unchanged
    assert_equal "Hello, world! 100% <ok>", T.sanitize("Hello, world! 100% <ok>")
  end

  def test_unicode_text_is_preserved
    text = "Grüße, 日本語, emoji 🎉"
    assert_equal text, T.sanitize(text)
  end

  def test_is_idempotent
    once = T.sanitize("x#{ESC}[31my")
    assert_equal once, T.sanitize(once)
  end

  def test_nil_and_non_strings_are_coerced
    assert_equal "", T.sanitize(nil)
    assert_equal "42", T.sanitize(42)
    assert_equal "[1, 2]", T.sanitize([1, 2])
  end

  def test_binary_and_invalid_encoding_do_not_raise
    # A truncated multi-byte sequence off the wire must not turn the defensive
    # sanitizer itself into the failure.
    invalid = "abc\xC3".dup.force_encoding(Encoding::ASCII_8BIT)
    out = T.sanitize(invalid)

    assert_kind_of String, out
    assert out.valid_encoding?
    assert_includes out, "abc"
  end

  def test_binary_string_with_escape_byte_is_neutralized
    invalid = "a#{ESC}[2Jb\xFF".dup.force_encoding(Encoding::ASCII_8BIT)
    out = T.sanitize(invalid)

    refute_includes out, ESC
    assert_includes out, "\\e[2J"
  end
end
