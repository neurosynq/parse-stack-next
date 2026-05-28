require_relative "../../test_helper"
require_relative "../../support/snapshot_helper"
require "minitest/autorun"

# Snapshot regression coverage for the aggregation-pipeline builders that
# sit alongside Parse::Query#compile but follow a different code path:
#
# * GroupBy#pipeline / GroupByDate#pipeline — build $match + $group + $project
#   pipelines from the same where-clause that #compile would otherwise emit
#   as a REST `where` hash.
# * aggregate_from_query — promotes $inQuery/$notInQuery into $lookup stages,
#   appends $sort / $skip / $limit / $project, and decides REST vs mongo-direct
#   routing based on whether $lookup stages were emitted.
#
# Each of these is a separate translation from the same Parse::Query state and
# is exactly where REST and mongo-direct can silently disagree as the SDK
# rewrites pipelines for direct-Mongo routing.
class AggregatePost < Parse::Object
  parse_class "AggregatePost"
  property :title, :string
  property :category, :string
  property :likes, :integer
  property :published_at, :date
  belongs_to :author, as: :user
  belongs_to :workspace, as: :snap_workspace
end

class SnapWorkspace < Parse::Object
  parse_class "SnapWorkspace"
  property :name, :string
  property :active, :boolean
end

class AggregatePipelineSnapshotTest < Minitest::Test
  GROUP = "aggregate_pipeline".freeze

  def test_group_by_count_basic
    g = AggregatePost.query.group_by(:category)
    assert_snapshot(g.pipeline.as_json, name: "group_by_count_basic", group: GROUP)
  end

  def test_group_by_with_where_filter
    g = AggregatePost.where(:likes.gt => 10).group_by(:category)
    assert_snapshot(g.pipeline.as_json, name: "group_by_with_where", group: GROUP)
  end

  def test_group_by_ordered_by_value_desc
    # Pushes a $sort on the aggregated value into the pipeline.
    g = AggregatePost.query.group_by(:category).order(value: :desc)
    assert_snapshot(g.pipeline.as_json, name: "group_by_order_value_desc", group: GROUP)
  end

  def test_group_by_ordered_by_key_asc
    g = AggregatePost.query.group_by(:category).order(key: :asc)
    assert_snapshot(g.pipeline.as_json, name: "group_by_order_key_asc", group: GROUP)
  end

  def test_group_by_pointer_field
    # Grouping by a pointer field should format the field name with the
    # `_p_` prefix used in MongoDB storage.
    g = AggregatePost.query.group_by(:author)
    assert_snapshot(g.pipeline.as_json, name: "group_by_pointer_field", group: GROUP)
  end

  def test_group_by_date_month
    g = AggregatePost.query.group_by_date(:published_at, :month)
    assert_snapshot(g.pipeline.as_json, name: "group_by_date_month", group: GROUP)
  end

  def test_group_by_date_day_with_timezone
    g = AggregatePost.query.group_by_date(:published_at, :day, timezone: "America/New_York")
    assert_snapshot(g.pipeline.as_json, name: "group_by_date_day_timezone", group: GROUP)
  end

  def test_aggregate_from_query_with_order_limit
    # aggregate_from_query is the entry point that translates a fully-built
    # Parse::Query (where + order + limit + skip + keys) into a complete
    # pipeline. Snapshot the constructed Aggregation's pipeline.
    q = AggregatePost.where(:likes.gt => 5).order(:likes.desc).limit(10).skip(5).keys(:title, :likes)
    agg = q.aggregate_from_query
    assert_snapshot(agg.pipeline.as_json, name: "aggregate_from_query_full", group: GROUP)
  end

  def test_aggregate_from_query_minimal
    # No where, no order — should produce an empty pipeline. Pinning this
    # catches accidental injection of default stages.
    q = AggregatePost.query
    agg = q.aggregate_from_query
    assert_snapshot(agg.pipeline.as_json, name: "aggregate_from_query_minimal", group: GROUP)
  end

  # --- $inQuery / $notInQuery → $lookup rewrite ----------------------------
  # The marquee path for "pipeline rewrite for direct-Mongo routing": a
  # Parse-style `$inQuery` constraint compiles to a `$lookup` stage when the
  # pipeline goes through aggregate_from_query, with auto-promotion to
  # mongo_direct because Parse Server's REST aggregate cannot resolve cross-
  # class lookups. Snapshot the rewritten pipeline shape AND the auto-
  # promotion flag so a regression in either is loud.

  def test_in_query_rewrites_to_lookup
    inner = SnapWorkspace.where(:active => true)
    q = AggregatePost.where(:workspace.matches => inner)
    agg = q.aggregate_from_query
    assert_snapshot(
      { "pipeline" => agg.pipeline.as_json, "mongo_direct" => agg.mongo_direct },
      name: "in_query_lookup_rewrite", group: GROUP,
    )
  end

  def test_not_in_query_rewrites_to_lookup
    inner = SnapWorkspace.where(:active => false)
    q = AggregatePost.where(:workspace.excludes => inner)
    agg = q.aggregate_from_query
    assert_snapshot(
      { "pipeline" => agg.pipeline.as_json, "mongo_direct" => agg.mongo_direct },
      name: "not_in_query_lookup_rewrite", group: GROUP,
    )
  end

  def test_in_query_mixed_with_scalar_constraints
    # A mixed where (subquery + scalar) should split into a remaining $match
    # for scalar bits plus the $lookup + post-lookup $match for the subquery.
    inner = SnapWorkspace.where(:active => true)
    q = AggregatePost.where(:workspace.matches => inner).where(:likes.gt => 0)
    agg = q.aggregate_from_query
    assert_snapshot(
      { "pipeline" => agg.pipeline.as_json, "mongo_direct" => agg.mongo_direct },
      name: "in_query_mixed_constraints", group: GROUP,
    )
  end
end
