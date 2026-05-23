# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/atlas_search"

# Unit tests for the internal-field stripping and the +allow_raw+ gate
# that protect raw-mode Atlas Search results from disclosing Parse Server
# internal columns (bcrypt hashes, session tokens, reset tokens).
class AtlasSearchRawSanitizationTest < Minitest::Test
  def setup
    Parse::AtlasSearch.reset!
  end

  def teardown
    Parse::AtlasSearch.reset!
  end

  # --- strip_internal_fields ------------------------------------------

  def test_strip_removes_password_hash
    out = Parse::PipelineSecurity.strip_internal_fields(
      "objectId" => "abc", "_hashed_password" => "$2a$10$xxxxx",
    )
    assert_equal({ "objectId" => "abc" }, out)
  end

  def test_strip_removes_session_and_reset_tokens
    out = Parse::PipelineSecurity.strip_internal_fields(
      "_session_token" => "r:xxx",
      "_email_verify_token" => "yyy",
      "_perishable_token" => "zzz",
      "_password_history" => ["old"],
      "name" => "alice",
    )
    assert_equal({ "name" => "alice" }, out)
  end

  def test_strip_removes_acl_columns
    out = Parse::PipelineSecurity.strip_internal_fields(
      "_rperm" => ["*"], "_wperm" => ["userX"], "title" => "t",
    )
    assert_equal({ "title" => "t" }, out)
  end

  def test_strip_passthrough_for_non_hash
    assert_nil Parse::PipelineSecurity.strip_internal_fields(nil)
    assert_equal "x", Parse::PipelineSecurity.strip_internal_fields("x")
  end

  def test_strip_does_not_mutate_input
    input = { "_hashed_password" => "x", "ok" => 1 }
    Parse::PipelineSecurity.strip_internal_fields(input)
    assert_equal "x", input["_hashed_password"]
  end

  # --- sanitize_raw_results -------------------------------------------

  def test_sanitize_raw_results_strips_every_doc
    docs = [
      { "objectId" => "1", "_hashed_password" => "h1" },
      { "objectId" => "2", "_session_token" => "t2", "name" => "b" },
    ]
    out = Parse::AtlasSearch.send(:sanitize_raw_results, docs)
    assert_equal [{ "objectId" => "1" }, { "objectId" => "2", "name" => "b" }], out
  end

  # --- raw_mode? gating -----------------------------------------------

  def test_raw_mode_returns_false_when_caller_did_not_request_raw
    Parse::AtlasSearch.allow_raw = true
    refute Parse::AtlasSearch.send(:raw_mode?, nil)
    refute Parse::AtlasSearch.send(:raw_mode?, false)
  end

  def test_raw_mode_honored_when_allow_raw_is_true
    Parse::AtlasSearch.allow_raw = true
    assert Parse::AtlasSearch.send(:raw_mode?, true)
  end

  def test_raw_mode_refused_when_allow_raw_is_false
    Parse::AtlasSearch.allow_raw = false
    refute Parse::AtlasSearch.send(:raw_mode?, true)
  end

  def test_raw_mode_falls_back_to_env_default_when_unset
    Parse::AtlasSearch.allow_raw = nil
    expected = Parse::AtlasSearch.send(:default_allow_raw)
    assert_equal expected, Parse::AtlasSearch.send(:raw_mode?, true)
  end

  def test_default_allow_raw_is_false_in_production
    original_rack = ENV["RACK_ENV"]
    original_rails = ENV["RAILS_ENV"]
    ENV["RACK_ENV"] = "production"
    ENV["RAILS_ENV"] = nil
    refute Parse::AtlasSearch.send(:default_allow_raw)
  ensure
    ENV["RACK_ENV"] = original_rack
    ENV["RAILS_ENV"] = original_rails
  end

  def test_default_allow_raw_is_true_in_development
    original_rack = ENV["RACK_ENV"]
    original_rails = ENV["RAILS_ENV"]
    ENV["RACK_ENV"] = "development"
    ENV["RAILS_ENV"] = nil
    assert Parse::AtlasSearch.send(:default_allow_raw)
  ensure
    ENV["RACK_ENV"] = original_rack
    ENV["RAILS_ENV"] = original_rails
  end

  def test_default_allow_raw_is_false_when_env_unset
    original_rack = ENV["RACK_ENV"]
    original_rails = ENV["RAILS_ENV"]
    ENV["RACK_ENV"] = nil
    ENV["RAILS_ENV"] = nil
    refute Parse::AtlasSearch.send(:default_allow_raw)
  ensure
    ENV["RACK_ENV"] = original_rack
    ENV["RAILS_ENV"] = original_rails
  end

  # --- process_search_results never returns hashed_password ----------

  def test_process_search_results_raw_strips_hashed_password
    Parse::AtlasSearch.allow_raw = true
    raw = [{ "objectId" => "abc", "_hashed_password" => "secret" }]
    result = Parse::AtlasSearch.send(:process_search_results, raw, "User", true)
    assert_kind_of Parse::AtlasSearch::SearchResult, result
    result.results.each { |doc| refute doc.key?("_hashed_password") }
    result.raw_results.each { |doc| refute doc.key?("_hashed_password") }
  end

  def test_process_search_results_ignores_raw_when_allow_raw_false
    Parse::AtlasSearch.allow_raw = false
    raw = [{ "_id" => "abc", "_hashed_password" => "secret", "title" => "t" }]
    result = Parse::AtlasSearch.send(:process_search_results, raw, "Song", true)
    # When raw is suppressed we go through the non-raw converter; we
    # only assert no internal fields surfaced on raw_results either.
    result.raw_results.each { |doc| refute doc.key?("_hashed_password") }
  end
end
