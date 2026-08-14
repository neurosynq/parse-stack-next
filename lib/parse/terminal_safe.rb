# encoding: UTF-8
# frozen_string_literal: true

module Parse
  # Neutralizes terminal control sequences in untrusted text before it is
  # written to a terminal, a log record, or an IRB `inspect` line.
  #
  # Parse Server returns whatever a tenant stored. Any string that originates
  # in the database, in a server error message, or in an LLM answer is
  # attacker-influenced, and a raw ESC byte in that string is not inert once it
  # reaches a TTY. It can clear the screen, rewrite lines the operator has
  # already read, retitle the window, or (via OSC 52) write the attacker's
  # payload into the system clipboard so the operator's next paste runs it.
  # Bidirectional overrides are the same class of problem: they reorder a line
  # so what the operator reads is not what the bytes say.
  #
  # This module is the SDK's single answer to that. It escapes rather than
  # deletes, so the offending bytes stay visible in the output (rendered as
  # `\e`, `\u202E`, and friends) and an operator can still see that
  # something tried.
  #
  # It sanitizes *rendering*, never storage. `result.text`, `object.title`, and
  # the parsed response body keep their exact bytes. Only the human-readable
  # form built for a terminal or a log line runs through here.
  #
  # @example Rendering an untrusted value
  #   puts Parse::TerminalSafe.sanitize(post.title)
  #
  # @example A single-line log record. Newlines are escaped too, so a stored
  #   value cannot forge a second log entry.
  #   logger.warn "#{status} - #{Parse::TerminalSafe.sanitize_line(error)}"
  module TerminalSafe
    extend self

    # Codepoint ranges neutralized on every call:
    #
    # - 0x00-0x08, 0x0B-0x1F: C0 controls except TAB (0x09) and LF (0x0A).
    #   This is where ESC (0x1B, the CSI/OSC/DCS introducer), BEL (0x07, the
    #   OSC string terminator), CR (0x0D, overwrite-the-line), and BS (0x08,
    #   erase-the-previous-character) live.
    # - 0x7F: DEL.
    # - 0x80-0x9F: C1 controls, the 8-bit forms of the same introducers
    #   (0x9B is CSI, 0x9D is OSC, 0x90 is DCS).
    # - 0x061C: Arabic letter mark, an implicit bidirectional control that
    #   reorders a line exactly like the explicit marks below.
    # - 0x200B-0x200F: zero-width space, non-joiner, joiner, LRM, RLM.
    # - 0x2028-0x2029: line and paragraph separator. Widely treated as a line
    #   break by terminals, editors, and log readers, so leaving them intact
    #   would reintroduce the forged-record problem that escaping LF solves.
    #   A legitimate line break is LF, which is preserved.
    # - 0x202A-0x202E: bidirectional embedding and override.
    # - 0x2060-0x2064: word joiner and the invisible math operators.
    # - 0x2066-0x2069: the bidirectional isolates.
    # - 0xFEFF: zero-width no-break space (a BOM appearing mid-string).
    #
    # TAB and LF are deliberately absent: both are ordinary formatting in
    # multi-line output. {#sanitize_line} escapes LF as well.
    UNSAFE_RANGES = [
      0x00..0x08, 0x0B..0x1F, 0x7F..0x9F,
      0x061C..0x061C,
      0x200B..0x200F, 0x2028..0x2029, 0x202A..0x202E,
      0x2060..0x2064, 0x2066..0x2069,
      0xFEFF..0xFEFF,
    ].freeze

    # Built from codepoints rather than written as literal escapes so the
    # source of this file stays free of the very bytes it defends against.
    def self.build_pattern(ranges)
      body = ranges.map { |r| format("\\u{%04X}-\\u{%04X}", r.first, r.last) }.join
      Regexp.new("[#{body}]")
    end
    private_class_method :build_pattern

    UNSAFE_RE = build_pattern(UNSAFE_RANGES)

    # The same set plus LF, for output that must occupy exactly one line.
    UNSAFE_LINE_RE = build_pattern(UNSAFE_RANGES + [0x0A..0x0A])

    # Readable escapes for the controls an operator is most likely to see.
    # Everything else falls back to `\xNN` or `\uNNNN`.
    NAMED_ESCAPES = {
      "\0" => "\\0",
      "\a" => "\\a",
      "\b" => "\\b",
      "\n" => "\\n",
      "\v" => "\\v",
      "\f" => "\\f",
      "\r" => "\\r",
      "\e" => "\\e",
    }.freeze

    # Escape terminal control sequences in `str`, preserving newlines and tabs.
    #
    # @param str [String, #to_s, nil] untrusted text.
    # @return [String] the same text with control characters escaped. Non-UTF-8
    #   and invalid-encoding input is coerced to UTF-8 first, so this never
    #   raises on a binary response body.
    def sanitize(str)
      escape(str, UNSAFE_RE)
    end

    # Escape terminal control sequences and newlines, so untrusted text cannot
    # forge additional lines. Use for anything written as a single log record
    # or a single console line.
    #
    # @param str [String, #to_s, nil] untrusted text.
    # @return [String]
    def sanitize_line(str)
      escape(str, UNSAFE_LINE_RE)
    end

    private

    def escape(str, pattern)
      s = coerce(str)
      return s unless s.match?(pattern)
      s.gsub(pattern) { |ch| escape_char(ch) }
    end

    # Force the input to valid UTF-8 without raising. A response body read off
    # the wire can be ASCII-8BIT, and a truncated multi-byte sequence is not
    # valid UTF-8. Either would make `match?` raise ArgumentError, which is
    # exactly the wrong outcome for a defensive sanitizer.
    def coerce(str)
      s = str.is_a?(String) ? str : str.to_s
      s = s.dup.force_encoding(Encoding::UTF_8) unless s.encoding == Encoding::UTF_8
      s = s.scrub("�") unless s.valid_encoding?
      s
    end

    def escape_char(ch)
      named = NAMED_ESCAPES[ch]
      return named if named
      cp = ch.ord
      cp <= 0xFF ? format("\\x%02X", cp) : format("\\u%04X", cp)
    end
  end
end
