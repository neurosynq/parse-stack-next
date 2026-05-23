# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Tests for Parse::Agent::RelationGraph and the per-class edge embedding
# performed by Parse::Agent::MetadataRegistry.enriched_schema.
#
# Uses small fixture classes wired with belongs_to / has_many :through =>
# :relation declarations to exercise the auto-derive path with no extra DSL.
class AgentRelationGraphTest < Minitest::Test
  class RGFCompany < Parse::Object
    parse_class "RGFCompany"
    property :name, :string
  end

  class RGFUser < Parse::Object
    parse_class "RGFUser"
    property :handle, :string
    belongs_to :company, as: "RGFCompany"
  end

  class RGFPost < Parse::Object
    parse_class "RGFPost"
    property :title, :string
    belongs_to :author, as: "RGFUser"
    has_many :tags, as: "RGFTag", through: :relation
  end

  class RGFTag < Parse::Object
    parse_class "RGFTag"
    property :label, :string
  end

  # Fixture for the wire-name override path: declares `field: "awesomeFans"`
  # on a has_many :through => :relation so the on-the-wire column name
  # differs from the Ruby accessor. The graph must emit the wire name.
  class RGFBand < Parse::Object
    parse_class "RGFBand"
    property :name, :string
    has_many :fans, as: "RGFFan", through: :relation, field: "awesomeFans"
  end

  class RGFFan < Parse::Object
    parse_class "RGFFan"
    property :name, :string
  end

  # ============================================================
  # Edge derivation
  # ============================================================

  def test_belongs_to_emits_one_to_many_edge_from_target_to_owner
    edges = Parse::Agent::RelationGraph.build
    edge = edges.find { |e| e[:via] == "RGFUser.company" }
    refute_nil edge, "should emit edge for RGFUser.company belongs_to RGFCompany"
    assert_equal "RGFCompany", edge[:from]
    assert_equal "RGFUser", edge[:to]
    assert_equal "1:N", edge[:cardinality]
    assert_equal :belongs_to, edge[:kind]
  end

  def test_belongs_to_chain_produces_company_user_post_edges
    edges = Parse::Agent::RelationGraph.build
    vias = edges.map { |e| e[:via] }
    assert_includes vias, "RGFUser.company"
    assert_includes vias, "RGFPost.author"
  end

  def test_has_many_relation_emits_n_to_m_edge
    edges = Parse::Agent::RelationGraph.build
    edge = edges.find { |e| e[:via] == "RGFPost.tags" }
    refute_nil edge, "should emit edge for RGFPost.tags has_many :through => :relation"
    assert_equal "RGFPost", edge[:from]
    assert_equal "RGFTag", edge[:to]
    assert_equal "N:M", edge[:cardinality]
    assert_equal :relation, edge[:kind]
  end

  def test_has_many_relation_with_field_override_uses_wire_name
    # has_many :fans, field: "awesomeFans", through: :relation — the Ruby
    # accessor is :fans but the on-the-wire column is "awesomeFans". An LLM
    # filtering by relation must see the wire name, otherwise its query
    # constraint targets a column that doesn't exist.
    edges = Parse::Agent::RelationGraph.build
    edge = edges.find { |e| e[:from] == "RGFBand" && e[:to] == "RGFFan" }
    refute_nil edge, "expected RGFBand → RGFFan edge from has_many :through => :relation"
    assert_equal "RGFBand.awesomeFans", edge[:via],
                 "via must reflect the field_map wire name, not the Ruby key"
  end

  def test_edges_are_deduplicated
    edges = Parse::Agent::RelationGraph.build
    keys = edges.map { |e| [e[:from], e[:to], e[:via]] }
    assert_equal keys.size, keys.uniq.size
  end

  # ============================================================
  # System-class filtering (parity with explore_database prompt guidance)
  # ============================================================

  def test_system_classes_other_than_user_and_role_are_excluded_from_walk
    # Inject a fake Parse::Object subclass with a `_`-prefixed parse_class to
    # confirm candidate_classes filters it out by default. _User and _Role
    # remain allowed.
    excluded = Class.new(Parse::Object) do
      def self.name; "TestSession"; end
      parse_class "_Session"
      belongs_to :related_user, as: "RGFUser"
    end
    refute_includes Parse::Agent::RelationGraph.send(:candidate_classes), excluded,
                    "_Session-class fixtures must be filtered when no agent_visible set is registered"

    # And the edge it would have contributed is not present
    edges = Parse::Agent::RelationGraph.build
    refute(edges.any? { |e| e[:via] == "_Session.relatedUser" },
           "edges originating in filtered system classes must not appear")
  ensure
    # Keep the rest of the test suite clean — drop the fixture
    Parse::Object.descendants.delete(excluded) if defined?(excluded) && excluded
  end

  # ============================================================
  # Subset filtering
  # ============================================================

  def test_subset_keeps_only_edges_where_both_endpoints_are_in_set
    edges = Parse::Agent::RelationGraph.build(classes: %w[RGFUser RGFPost])
    vias = edges.map { |e| e[:via] }
    assert_includes vias, "RGFPost.author", "User-Post edge should pass the subset filter"
    refute_includes vias, "RGFUser.company", "Company-User edge should be dropped (RGFCompany not in subset)"
    refute_includes vias, "RGFPost.tags", "Post-Tag edge should be dropped (RGFTag not in subset)"
  end

  def test_subset_with_no_matching_classes_returns_empty
    edges = Parse::Agent::RelationGraph.build(classes: %w[NoSuchClassA NoSuchClassB])
    assert_empty edges
  end

  # ============================================================
  # ASCII rendering
  # ============================================================

  def test_to_ascii_aligns_columns_and_includes_cardinality
    edges = Parse::Agent::RelationGraph.build(classes: %w[RGFCompany RGFUser RGFPost RGFTag])
    diagram = Parse::Agent::RelationGraph.to_ascii(edges)
    assert_match(/RGFCompany.*─1:N→.*RGFUser.*\(RGFUser\.company\)/, diagram)
    assert_match(/RGFPost.*─N:M→.*RGFTag.*\(RGFPost\.tags\)/, diagram)
  end

  def test_to_ascii_empty_edges_returns_placeholder
    assert_equal "(no class relations defined)", Parse::Agent::RelationGraph.to_ascii([])
  end

  # ============================================================
  # Per-class edges_for helper
  # ============================================================

  def test_edges_for_separates_outgoing_and_incoming
    result = Parse::Agent::RelationGraph.edges_for("RGFUser")
    outgoing_vias = result[:outgoing].map { |e| e[:via] }
    incoming_vias = result[:incoming].map { |e| e[:via] }

    # Convention: belongs_to emits edges from target → owner, so for
    # `RGFPost belongs_to :author, as: "RGFUser"` the edge is
    # `RGFUser ─1:N→ RGFPost (RGFPost.author)`. RGFUser is the `from` side,
    # so RGFPost.author appears in RGFUser's outgoing list.
    assert_includes outgoing_vias, "RGFPost.author"

    # RGFUser is the `to` side of `RGFCompany ─1:N→ RGFUser (RGFUser.company)`
    assert_includes incoming_vias, "RGFUser.company"
  end

  # ============================================================
  # MetadataRegistry embedding
  # ============================================================

  def test_enriched_schema_includes_relations_block_for_class_with_edges
    server_schema = {
      "className" => "RGFUser",
      "fields" => {
        "objectId" => { "type" => "String" },
        "createdAt" => { "type" => "Date" },
        "updatedAt" => { "type" => "Date" },
        "handle" => { "type" => "String" },
        "company" => { "type" => "Pointer", "targetClass" => "RGFCompany" },
      },
    }

    # Force has_agent_metadata? to true so enrichment runs; agent_description
    # alone suffices.
    AgentRelationGraphTest::RGFUser.agent_description "test user"
    result = Parse::Agent::MetadataRegistry.enriched_schema("RGFUser", server_schema)

    assert result["relations"].is_a?(Hash)
    out = result["relations"]["outgoing"]
    inc = result["relations"]["incoming"]
    assert(out.any? { |e| e["via"] == "RGFPost.author" }, "expected outgoing edge to Post")
    assert(inc.any? { |e| e["via"] == "RGFUser.company" }, "expected incoming edge from Company")

    # Compact form drops :kind; keeps cardinality
    sample = result["relations"]["outgoing"].first
    refute sample.key?(:kind), "compact edge should not carry :kind symbol"
    assert sample.key?("cardinality")
  end
end
