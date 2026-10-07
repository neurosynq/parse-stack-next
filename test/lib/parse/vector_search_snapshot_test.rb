# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../support/snapshot_helper"
require "minitest/autorun"
require "set"
require "parse/vector_search/hybrid"

# Snapshot regression coverage for three security-relevant shapes that
# had none (roadmap PC-6):
#
# * `vector_search/` — the `$vectorSearch` pipeline Parse::VectorSearch.search
#   sends to Atlas, including where the ACL `$match` lands relative to the
#   search stage, for master, user-session, and role scopes.
# * `rank_fusion/` — the native `$rankFusion` hybrid pipeline, whose ACL
#   `$match` runs AFTER fusion; pins that ordering and the oversampled
#   candidate window that compensates for it.
# * `clp_scope/` — the `protectedFields` strip set resolved per claim set,
#   and the redaction it applies to rows and embedded sub-documents.
#
# Nothing here executes against a server: collections are captured, the CLP
# cache is seeded, and ACL resolutions are built directly, so the shapes are
# the ones the live paths would emit for those inputs.
class VectorSearchSnapshotTest < Minitest::Test
  # Records each pipeline it is handed and returns no rows.
  class CapturingColl
    attr_reader :pipelines

    def initialize = @pipelines = []

    def aggregate(pipeline, _opts = {})
      @pipelines << pipeline
      []
    end

    def with(*) = self
  end

  def setup
    Parse::CLPScope.reset_cache!
  end

  def teardown
    Parse::CLPScope.reset_cache!
  end

  def resolution(mode:, permission_strings:, user_id: nil, strict_role: false)
    Parse::ACLScope::Resolution.new(
      mode: mode, permission_strings: permission_strings, user_id: user_id,
      session: nil, strict_role: strict_role,
    )
  end

  MASTER = Parse::ACLScope::Resolution.new(mode: :master, permission_strings: nil, user_id: nil,
                                           session: nil, strict_role: false)

  # ---- $vectorSearch ---------------------------------------------------

  def vector_pipeline(res, **search_opts)
    coll = CapturingColl.new
    Parse::MongoDB.stub(:require_gem!, nil) do
      Parse::MongoDB.stub(:available?, true) do
        Parse::MongoDB.stub(:collection, ->(_n, **_o) { coll }) do
          Parse::ACLScope.stub(:resolve!, ->(*, **) { res }) do
            Parse::CLPScope.stub(:permits?, ->(*, **) { true }) do
              Parse::CLPScope.stub(:protected_fields_for, ->(*, **) { Set.new }) do
                Parse::CLPScope.stub(:row_constraint_for!, ->(*, **) { nil }) do
                  Parse::VectorSearch.search("Song", field: "embedding", query_vector: [0.1, 0.2, 0.3],
                                                     k: 5, index: "song_vec", **search_opts)
                end
              end
            end
          end
        end
      end
    end
    assert_equal 1, coll.pipelines.size, "expected exactly one $vectorSearch aggregation"
    coll.pipelines.first
  end

  def test_vector_search_master_has_no_acl_match
    pipe = vector_pipeline(MASTER)
    refute(pipe.any? { |s| s.key?("$match") && s["$match"].key?("_rperm") })
    assert_snapshot(pipe, name: "master", group: "vector_search")
  end

  def test_vector_search_user_session_matches_after_search
    res = resolution(mode: :session, permission_strings: ["role:Editor", "u_alice", "*"], user_id: "u_alice")
    pipe = vector_pipeline(res)
    assert_equal "$vectorSearch", pipe.first.keys.first, "$vectorSearch must stay stage 0"
    assert_snapshot(pipe, name: "user_session", group: "vector_search")
  end

  def test_vector_search_strict_role_excludes_public
    res = resolution(mode: :role, permission_strings: ["role:reporting"], strict_role: true)
    pipe = vector_pipeline(res)
    refute_includes JSON.generate(pipe), '"*"', "strict role scope must not admit public rows"
    assert_snapshot(pipe, name: "strict_role", group: "vector_search")
  end

  def test_vector_search_with_caller_filter
    res = resolution(mode: :session, permission_strings: ["u_alice", "*"], user_id: "u_alice")
    pipe = vector_pipeline(res, vector_filter: { "genre" => "rock" }, filter: { "plays" => { "$gt" => 10 } })
    assert_snapshot(pipe, name: "user_session_with_filters", group: "vector_search")
  end

  # ---- native $rankFusion ----------------------------------------------

  def native_pipeline(res)
    Parse::ACLScope.stub(:resolve!, ->(*, **) { res }) do
      Parse::VectorSearch::Hybrid.send(
        :native_pipeline, "Song",
        lexical: { query: "rain", index: "song_search" },
        vector: { query_vector: [0.1, 0.2], field: "embedding", index: "song_vec" },
        k: 5, fusion: { weights: { lexical: 0.4, vector: 0.6 } },
      )
    end
  end

  def test_rank_fusion_master
    assert_snapshot(native_pipeline(MASTER), name: "master", group: "rank_fusion")
  end

  def test_rank_fusion_scoped_acl_match_follows_fusion
    res = resolution(mode: :session, permission_strings: ["u_alice", "*"], user_id: "u_alice")
    pipe = native_pipeline(res)
    fusion_at = pipe.index { |s| s.key?("$rankFusion") }
    match_at = pipe.index { |s| s.key?("$match") && s["$match"].to_s.include?("_rperm") }
    limit_at = pipe.index { |s| s.key?("$limit") }
    assert_equal 0, fusion_at
    refute_nil match_at, "scoped native pipeline must carry an ACL match"
    assert_operator match_at, :>, fusion_at, "the ACL match runs after fusion"
    assert_operator limit_at, :>, match_at, "the final limit runs after the ACL match"
    assert_snapshot(pipe, name: "user_session", group: "rank_fusion")
  end

  # ---- clp_scope protectedFields ----------------------------------------

  CLP = {
    "find" => { "*" => true },
    "protectedFields" => {
      "*" => %w[email phone ssn],
      "role:Support" => %w[ssn],
      "u_owner" => [],
    },
  }.freeze

  def strip_set(claims)
    Parse::CLPScope.__cache_put("Customer", clp: CLP)
    Parse::CLPScope.protected_fields_for("Customer", claims).to_a.sort
  end

  def test_clp_protected_fields_per_claim_set
    shapes = {
      "public" => strip_set(["*"]),
      "support_role" => strip_set(["*", "role:Support"]),
      "owner" => strip_set(["*", "u_owner"]),
      "master" => Parse::CLPScope.protected_fields_for("Customer", nil).to_a.sort,
    }
    assert_equal %w[email phone ssn], shapes["public"]
    assert_equal [], shapes["owner"]
    assert_snapshot(shapes, name: "protected_fields_per_claim_set", group: "clp_scope")
  end

  def test_clp_redaction_reaches_embedded_documents
    rows = [
      { "_id" => "c1", "name" => "Ada", "email" => "a@x.test", "ssn" => "1",
        "account" => { "_id" => "a1", "email" => "nested@x.test", "plan" => "pro" } },
    ]
    Parse::CLPScope.redact_protected_fields!(rows, Set.new(strip_set(["*", "role:Support"])))
    refute rows.first.key?("ssn")
    assert_snapshot(rows, name: "redaction_support_role", group: "clp_scope")
  end
end
