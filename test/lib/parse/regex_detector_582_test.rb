# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/mongodb"
begin
  require "bson"
rescue LoadError
  nil
end

# Parse::RegexSecurity parses a pattern instead of matching it against a few
# substrings. Repeated groups that hold a quantifier, an alternation, or a
# backreference are refused on every gate (the REST where check, the
# mongo-direct pipeline walker, and the agent translator); repeats of a single
# atom and simple lookarounds pass on every gate.
class RegexDetector582Test < Minitest::Test
  # Shapes that hit PCRE's backtracking limit, or hide a quantifier.
  CATASTROPHIC = [
    "(a+)+$", "(a|aa)+$", "(a|a)+", "((a+))+", "([a)]+)+", "(a+){2,}", "(a+){20}",
    "(a+)(?#c)+", "(?#c)(a+)+", "(?x)(a+) +", "(?x:a)", "(\\w+)*z", "(.*a){12}",
    # An optional or variable-count element inside a repeated group gives
    # the engine a choice on every repeat.
    "^(a?){100}a{100}$", "(a?)+", "((a)?){50}", "(a{0,2}){10}", "(a??){20}", "(a?+){20}",
  ].freeze

  # Ordinary patterns that are not ReDoS shapes.
  ORDINARY = [
    "^(?!test)", "^.{1,255}$", "\\d{1,100}", "x{1000}", "^abc", "(?=\\d)\\w+", "(?<!foo)bar",
    "^foo.*bar.*$", "(ab)+", "(a+)?", "[a-z]+@[a-z]+\\.com", "^\\p{L}+$",
    "(ab){3}", "(a{2}){10}",
  ].freeze

  class RxDoc < Parse::Object
    parse_class "RxDoc"
    property :name, :string
  end

  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1/parse", application_id: "a",
                  api_key: "k", master_key: "mk")
    end
  end

  def translator
    Parse::Agent::ConstraintTranslator
  end

  def rest_compile(where)
    RxDoc.query(where).compile(encode: false)
  end

  def test_catastrophic_shapes_are_refused_on_every_gate
    CATASTROPHIC.each do |pattern|
      assert_raises(ArgumentError, "RegexSecurity accepted #{pattern}") { Parse::RegexSecurity.validate!(pattern) }
      assert_raises(ArgumentError, "REST where accepted #{pattern}") { rest_compile(name: { "$regex" => pattern }) }
      assert_raises(Parse::PipelineSecurity::Error, "pipeline accepted #{pattern}") do
        Parse::PipelineSecurity.validate_pipeline!([{ "$match" => { "name" => { "$regex" => pattern } } }])
      end
      assert_raises(Parse::PipelineSecurity::Error, "filter accepted #{pattern}") do
        Parse::PipelineSecurity.validate_filter!({ "name" => { "$regex" => pattern } })
      end
      assert_raises(translator::ConstraintSecurityError, "translator accepted #{pattern}") do
        translator.translate({ "name" => { "$regex" => pattern } })
      end
    end
  end

  def test_ordinary_patterns_pass_on_every_gate
    ORDINARY.each do |pattern|
      assert_equal pattern, Parse::RegexSecurity.validate!(pattern)
      rest_compile(name: { "$regex" => pattern })
      Parse::PipelineSecurity.validate_pipeline!([{ "$match" => { "name" => { "$regex" => pattern } } }])
      Parse::PipelineSecurity.validate_filter!({ "name" => { "$regex" => pattern } })
      assert translator.translate({ "name" => { "$regex" => pattern } })
    end
  end

  def test_unbalanced_and_unknown_constructs_are_refused
    ["((a)", "(a))", "[abc", "a**", "+a", "(?R)", "(?(1)a|b)", "\\"].each do |pattern|
      refute Parse::RegexSecurity.safe?(pattern), "accepted #{pattern.inspect}"
    end
  end

  def test_inline_flags_without_extended_mode_pass
    assert Parse::RegexSecurity.safe?("(?i-mx:Bob)")
    assert Parse::RegexSecurity.safe?("(?i)abc")
    refute Parse::RegexSecurity.safe?("(?xi)abc")
  end

  def test_extended_flag_is_refused_in_options_and_regexp_values
    assert_raises(ArgumentError) { rest_compile(name: { "$regex" => "^a", "$options" => "ix" }) }
    assert_raises(Parse::PipelineSecurity::Error) do
      Parse::PipelineSecurity.validate_filter!({ "name" => { "$regex" => "^a", "$options" => "x" } })
    end
    assert_raises(Parse::PipelineSecurity::Error) do
      Parse::PipelineSecurity.validate_filter!({ "name" => /a b/x })
    end
    assert_raises(translator::ConstraintSecurityError) do
      translator.translate({ "name" => { "$regex" => "^a", "$options" => "x" } })
    end
  end

  def test_dot_all_flag_is_accepted_on_the_translator
    assert translator.translate({ "name" => { "$regex" => "^a", "$options" => "is" } })
  end

  def test_long_escaped_literals_from_sdk_constraints_compile
    rest_compile(:name.contains => "a" * 499)
    rest_compile(:name.starts_with => "1.2.3." * 60)
    rest_compile(:name.ends_with => "x.y" * 150)
    Parse::PipelineSecurity.validate_filter!({ "name" => { "$regex" => "^" + Regexp.escape("1.2.3." * 80) } })
  end

  def test_non_literal_long_pattern_keeps_the_cap
    assert_raises(ArgumentError) { Parse::RegexSecurity.validate!("[ab]" * 200) }
  end

  def test_regex_match_requires_a_literal_pattern
    [{ "$literal" => "^a" }, { "$concat" => ["^", "a"] }, "$pattern", "$$var"].each do |operand|
      err = assert_raises(Parse::PipelineSecurity::Error, "accepted #{operand.inspect}") do
        Parse::PipelineSecurity.validate_pipeline!(
          [{ "$addFields" => { "hit" => { "$regexMatch" => { "input" => "$name", "regex" => operand } } } }],
        )
      end
      assert_equal :regex_not_literal, err.reason
    end
    Parse::PipelineSecurity.validate_pipeline!(
      [{ "$addFields" => { "hit" => { "$regexMatch" => { "input" => "$name", "regex" => "^a" } } } }],
    )
  end

  def test_dot_star_pair_is_not_literal_text_but_still_passes
    refute Parse::RegexSecurity.literal_pattern?(".*.*")
    assert Parse::RegexSecurity.safe?(".*.*")
    rest_compile(:name.contains => "")
    refute Parse::RegexSecurity.safe?("a.*.*b")
  end

  def test_find_is_allowed_again_under_nested_with_master_key
    raised = Parse.without_master_key do
      Parse.with_master_key do
        Parse::MongoDB.find("RxDoc", {})
        nil
      rescue StandardError => e
        e
      end
    end
    refute_kind_of Parse::ACLScope::ACLRequired, raised
  end
end
