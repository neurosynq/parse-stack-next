require_relative "../../test_helper"
require_relative "../../support/snapshot_helper"
require "minitest/autorun"

# Snapshot regression coverage for Parse::Query compile and pipeline output.
# The compiled REST `where` hash and the mongo-direct pipeline stages are the
# stable interface between the SDK and Parse Server / MongoDB — any drift in
# their shape is a routing or correctness bug. Snapshots normalize ObjectIds,
# timestamps, and hash key ordering before comparison; re-run with
# UPDATE_SNAPSHOTS=1 after an intentional change.
class SnapPost < Parse::Object
  parse_class "SnapPost"
  property :title, :string
  property :category, :string
  property :likes, :integer
  property :tags, :array
  property :published, :boolean
  property :archived, :boolean
  belongs_to :author, as: :user
end

class SnapComment < Parse::Object
  parse_class "SnapComment"
  property :body, :string
  property :approved, :boolean
  belongs_to :post, as: :snap_post
  belongs_to :author, as: :user
end

class QueryCompileSnapshotTest < Minitest::Test
  GROUP = "query_compile".freeze
  WIRE_GROUP = "query_wire".freeze

  def compile(query)
    # encode: false keeps the `where` clause as a Hash so the snapshot captures
    # the structural shape, not a serialization detail. as_json rolls nested
    # Parse::Pointer / constraint objects down to their plain-data form so the
    # normalizer can sort hash keys deterministically.
    query.compile(encode: false).as_json
  end

  # REST wire-shape: compile with encode: true (so the `where` clause is a
  # JSON string just like Parse Server sees it), then parse it back so the
  # snapshot normalizer can still sort keys deterministically. This is the
  # form that pins Date / Regexp / Pointer wire encodings, since `encode:
  # false` leaves Regexp objects as Ruby Regexps and Dates as Time-likes.
  def wire(query)
    compiled = query.compile(encode: true).dup
    compiled[:where] = JSON.parse(compiled[:where]) if compiled[:where].is_a?(String)
    compiled.as_json
  end

  def test_compound_or_with_mixed_constraints
    q1 = SnapPost.where(:category => "music").where(:likes.gt => 10)
    q2 = SnapPost.where(:published => true)
    or_query = Parse::Query.or(q1, q2)
    assert_snapshot(compile(or_query), name: "compound_or_mixed", group: GROUP)
  end

  def test_includes_keys_auto_merge
    q = SnapPost.query.keys(:title).includes(:author).limit(5)
    assert_snapshot(compile(q), name: "includes_keys_auto_merge", group: GROUP)
  end

  def test_count_shape
    # `count` is a query-state flag (`@count`) set by Parse::Query#count
    # before it calls compile + dispatches. Snapshot the compile output
    # under that flag without executing a real request. The defended-ivar
    # pattern catches a silent rename of the underlying state.
    q = SnapPost.query(:category => "music")
    refute_nil q.instance_variable_get(:@count),
               "Parse::Query no longer initializes @count — update this test"
    q.instance_variable_set(:@count, 1)
    assert_snapshot(compile(q), name: "count_shape", group: GROUP)
  end

  def test_marker_stripping_for_rest
    # Pipeline-producing constraints (e.g. :tags.size) must be stripped from
    # the REST `where` hash; the marker belongs only to the routing layer.
    # Snapshot the REST-shape next to the pipeline-shape to lock both in.
    q = SnapPost.where(:tags.size => { gt: 2 }).where(:category => "music")
    assert_snapshot(compile(q), name: "marker_stripping_rest", group: GROUP)
  end

  def test_pipeline_extraction
    # The complement of marker_stripping: the same constraint surfaced via
    # #pipeline should return just the aggregation stages, no REST scaffolding.
    q = SnapPost.where(:tags.size => { gt: 2 })
    assert_snapshot(q.pipeline.as_json, name: "pipeline_extraction", group: GROUP)
  end

  def test_pointer_constraint_compile
    # belongs_to constraints compile to a Pointer dict — the storage shape is
    # part of the REST contract and worth pinning.
    author = Parse::User.pointer("abcdef1234")
    q = SnapPost.where(:author => author).where(:archived => false)
    assert_snapshot(compile(q), name: "pointer_constraint", group: GROUP)
  end

  def test_order_and_limit
    q = SnapPost.query.order(:likes.desc, :title.asc).limit(20).skip(40)
    assert_snapshot(compile(q), name: "order_limit_skip", group: GROUP)
  end

  def test_regex_and_null_constraints
    q = SnapPost.where(:title.like => /^draft/i).where(:archived => nil)
    assert_snapshot(compile(q), name: "regex_and_null", group: GROUP)
  end

  # --- REST wire-format snapshots ------------------------------------------
  # encode: false leaves Ruby Regexps / Time-likes / Pointer objects in the
  # `where` hash, which is convenient for structural tests but does NOT pin
  # what Parse Server actually sees on the wire. These snapshots round-trip
  # through JSON.generate so Regexp serialization, Parse Date dicts, and
  # Pointer encoding are captured at the REST boundary.

  def test_wire_regex_serialization
    q = SnapPost.where(:title.like => /^draft/i)
    assert_snapshot(wire(q), name: "regex_serialization", group: WIRE_GROUP)
  end

  def test_wire_date_constraint
    fixed = Time.utc(2024, 1, 15, 12, 0, 0)
    q = SnapPost.where(:created_at.gt => fixed)
    assert_snapshot(wire(q), name: "date_gt_constraint", group: WIRE_GROUP)
  end

  def test_wire_pointer_constraint
    # The REST wire form of a pointer constraint is the Pointer JSON dict
    # inside a `where` value; pin that.
    author = Parse::User.pointer("abcdef1234")
    q = SnapPost.where(:author => author)
    assert_snapshot(wire(q), name: "pointer_constraint_wire", group: WIRE_GROUP)
  end

  # --- additional structural coverage --------------------------------------

  def test_pointer_array_containment
    # `$in` over an array of Pointer dicts — different code path from a
    # scalar pointer equality and an easy spot to silently break.
    a = Parse::User.pointer("abcdef1234")
    b = Parse::User.pointer("ghijkl5678")
    q = SnapPost.where(:author.in => [a, b])
    assert_snapshot(compile(q), name: "pointer_array_in", group: GROUP)
  end

  def test_exists_constraint
    q = SnapPost.where(:title.exists => true).where(:archived.exists => false)
    assert_snapshot(compile(q), name: "exists_constraint", group: GROUP)
  end

  def test_tags_all_array_constraint
    # `:tags.all => [...]` compiles to the `$all` REST operator (not a
    # pipeline). Snapshot under normalized array order — $all is set-semantic.
    q = SnapPost.where(:tags.all => ["jazz", "rock", "pop"])
    assert_snapshot(compile(q), name: "tags_all_array", group: GROUP)
  end

  def test_chained_or_via_pipe_operator
    # `|` between two Parse::Query objects is the Ruby-operator path into
    # Parse::Query.or — verifies the pipe shorthand compiles to the same
    # $or shape as the direct call.
    q1 = SnapPost.where(:category => "music")
    q2 = SnapPost.where(:category => "art")
    or_query = q1 | q2
    assert_snapshot(compile(or_query), name: "or_via_pipe_operator", group: GROUP)
  end
end
