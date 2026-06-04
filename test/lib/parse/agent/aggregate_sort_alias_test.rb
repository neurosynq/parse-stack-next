# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/agent"

# Regression lock for the $sort computed-alias policy. The v4.4.3
# forward-pass field-availability tracking already admits aliases produced
# by an earlier $group/$project/$addFields for use in a later $sort, while
# still refusing the bisect-oracle pattern (sorting on an alias that was
# projected FROM a denied class field — refused at the projection stage)
# and a direct $sort on a denied field. These tests pin that contract so a
# future change to walk_pipeline_stage! can't silently regress it.
class AggregateSortAliasTest < Minitest::Test
  class SortDoc < Parse::Object
    parse_class "SortAliasDoc"
    property :status, :string
    property :secret, :string
    agent_fields :status # secret is intentionally NOT in the allowlist
  end

  T = Parse::Agent::Tools

  def enforce(pipeline)
    T.enforce_pipeline_access_policy!("SortAliasDoc", pipeline)
  end

  def test_group_count_then_sort_count_allowed
    # The canonical top-K pattern: count is a computed alias from $group.
    enforce([
      { "$group" => { "_id" => "$status", "count" => { "$sum" => 1 } } },
      { "$sort"  => { "count" => -1 } },
    ])
  end

  def test_addfields_alias_then_sort_alias_allowed
    enforce([
      { "$addFields" => { "score" => { "$add" => [1, 2] } } },
      { "$sort"      => { "score" => -1 } },
    ])
  end

  def test_project_alias_then_sort_alias_allowed
    enforce([
      { "$project" => { "status" => 1, "label" => "$status" } },
      { "$sort"    => { "label" => 1 } },
    ])
  end

  def test_bisect_oracle_alias_from_denied_field_refused
    # $project x = $secret is refused at the projection stage, so the
    # downstream $sort on the alias can never become an ordering oracle.
    assert_raises(Parse::Agent::AccessDenied) do
      enforce([
        { "$project" => { "x" => "$secret" } },
        { "$sort"    => { "x" => 1 } },
      ])
    end
  end

  def test_direct_sort_on_denied_field_refused
    assert_raises(Parse::Agent::AccessDenied) do
      enforce([{ "$sort" => { "secret" => 1 } }])
    end
  end
end
