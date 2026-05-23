# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/mongodb"

# Unit tests for env-var URI resolution in Parse::MongoDB.configure.
# `ANALYTICS_DATABASE_URI` must take priority over `DATABASE_URI` so
# deployments can route direct reads at a dedicated analytics replica
# without touching the primary Parse Server connection string.
class MongoDBConfigureEnvTest < Minitest::Test
  def setup
    @stash_analytics = ENV.delete("ANALYTICS_DATABASE_URI")
    @stash_database  = ENV.delete("DATABASE_URI")
    Parse::MongoDB.reset!
  end

  def teardown
    ENV["ANALYTICS_DATABASE_URI"] = @stash_analytics if @stash_analytics
    ENV["DATABASE_URI"]           = @stash_database  if @stash_database
    Parse::MongoDB.reset!
  end

  def test_env_keys_priority_order
    assert_equal %w[ANALYTICS_DATABASE_URI DATABASE_URI],
                 Parse::MongoDB::ENV_URI_KEYS,
                 "ANALYTICS_DATABASE_URI must come first so deployments can override the primary URI"
  end

  def test_analytics_uri_takes_priority_over_database_uri
    ENV["ANALYTICS_DATABASE_URI"] = "mongodb://analytics:27017/db"
    ENV["DATABASE_URI"]           = "mongodb://primary:27017/db"
    Parse::MongoDB.configure(enabled: true, verify_role: false)
    assert_equal "mongodb://analytics:27017/db", Parse::MongoDB.uri
  end

  def test_falls_back_to_database_uri_when_analytics_unset
    ENV["DATABASE_URI"] = "mongodb://primary:27017/db"
    Parse::MongoDB.configure(enabled: true, verify_role: false)
    assert_equal "mongodb://primary:27017/db", Parse::MongoDB.uri
  end

  def test_explicit_uri_argument_overrides_env
    ENV["ANALYTICS_DATABASE_URI"] = "mongodb://analytics:27017/db"
    Parse::MongoDB.configure(uri: "mongodb://explicit:27017/db", enabled: true, verify_role: false)
    assert_equal "mongodb://explicit:27017/db", Parse::MongoDB.uri
  end

  def test_raises_when_no_uri_available
    err = assert_raises(ArgumentError) { Parse::MongoDB.configure(enabled: true, verify_role: false) }
    assert_match(/ANALYTICS_DATABASE_URI/, err.message)
    assert_match(/DATABASE_URI/, err.message)
  end

  def test_empty_string_env_var_is_treated_as_unset
    ENV["ANALYTICS_DATABASE_URI"] = ""
    ENV["DATABASE_URI"]           = "mongodb://primary:27017/db"
    Parse::MongoDB.configure(enabled: true, verify_role: false)
    assert_equal "mongodb://primary:27017/db", Parse::MongoDB.uri
  end

  def test_resolve_uri_from_env_returns_nil_when_none_set
    assert_nil Parse::MongoDB.resolve_uri_from_env
  end

  def test_database_extracted_from_resolved_uri
    ENV["ANALYTICS_DATABASE_URI"] = "mongodb://analytics:27017/myparseanalytics"
    Parse::MongoDB.configure(enabled: true, verify_role: false)
    assert_equal "myparseanalytics", Parse::MongoDB.database
  end
end
