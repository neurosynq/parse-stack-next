require_relative "../../test_helper"
require "parse/acl_scope"
require "parse/clp_scope"

class TestACLScope < Minitest::Test
  def setup
    Parse::ACLScope.reset_warning_state!
    Parse::ACLScope.require_session_token = false
    # Wave-3 TRACK-CLP-2: CLPScope now fails closed on unresolvable
    # schema. The existing rewrite/redact tests construct synthetic
    # pipelines naming classes like "User", "Region", "OtherCollection"
    # — without a Parse Server those schemas are :unresolvable and the
    # new cross-class CLP gate (Wave-3 TRACK-ACL-3) would deny every
    # join. Pre-populate the cache with permissive CLP for the test
    # classes so the legacy rewrite assertions still exercise the join
    # rewriter, not the new CLP gate. The CLP-gate behavior is covered
    # by dedicated tests at the bottom of the file.
    Parse::CLPScope.reset_cache!
    # IMPORTANT: any future test in this file that needs to assert
    # FAIL-CLOSED behavior on one of these class names MUST call
    # `Parse::CLPScope.invalidate!(name)` then `__cache_put` it with a
    # restrictive CLP AFTER this setup block runs — otherwise the
    # test will silently pass against the permissive seed below.
    %w[User Region OtherCollection PublicJoin Report].each do |cls|
      Parse::CLPScope.__cache_put(cls, clp: { "find" => { "*" => true } })
    end
  end

  def teardown
    Parse::ACLScope.require_session_token = false
    Parse::CLPScope.reset_cache!
  end

  # ---- resolve!: master mode ----

  def test_master_mode
    res = Parse::ACLScope.resolve!({ master: true }, method_name: :test)
    assert res.master?
    refute res.session?
    assert_nil res.permission_strings
  end

  def test_master_mode_skips_injection
    res = Parse::ACLScope.resolve!({ master: true }, method_name: :test)
    assert_nil Parse::ACLScope.match_stage_for(res)
  end

  # ---- resolve!: acl_user mode ----

  def test_acl_user_mode
    user = Parse::Pointer.new("_User", "user_abc")
    res = Parse::ACLScope.resolve!({ acl_user: user }, method_name: :test)
    assert res.session?
    refute res.master?
    assert_includes res.permission_strings, "user_abc"
    assert_includes res.permission_strings, "*"
    assert_equal res.user_id, "user_abc"
  end

  def test_acl_user_rejects_non_user
    assert_raises(ArgumentError) do
      Parse::ACLScope.resolve!({ acl_user: "string" }, method_name: :test)
    end
  end

  # ---- resolve!: acl_role mode ----

  def test_acl_role_via_string_with_role_prefix_strip
    # Without a real Parse Server we can't fetch a role by name; just
    # confirm the strip logic and rejection of empty names.
    assert_raises(ArgumentError) do
      Parse::ACLScope.resolve!({ acl_role: "role:" }, method_name: :test)
    end
  end

  def test_acl_role_rejects_bad_type
    assert_raises(ArgumentError) do
      Parse::ACLScope.resolve!({ acl_role: 12345 }, method_name: :test)
    end
  end

  # ---- resolve!: mutual exclusion ----

  def test_rejects_master_and_session_token
    assert_raises(ArgumentError) do
      Parse::ACLScope.resolve!({ master: true, session_token: "x" }, method_name: :test)
    end
  end

  def test_rejects_acl_user_and_master
    assert_raises(ArgumentError) do
      Parse::ACLScope.resolve!(
        { acl_user: Parse::Pointer.new("_User", "abc"), master: true },
        method_name: :test,
      )
    end
  end

  # ---- resolve!: public fallback + warning ----

  def test_public_fallback_emits_banner_once
    _out, err1 = capture_io do
      Parse::ACLScope.resolve!({}, method_name: :first_call)
    end
    assert_match(/SECURITY/, err1)

    _out, err2 = capture_io do
      Parse::ACLScope.resolve!({}, method_name: :second_call)
    end
    refute_match(/SECURITY/, err2)
  end

  def test_public_fallback_returns_public_resolution
    capture_io { Parse::ACLScope.resolve!({}, method_name: :test) }
    res = Parse::ACLScope.resolve!({}, method_name: :test)
    assert res.public?
    assert_includes res.permission_strings, "*"
    assert_nil res.user_id
  end

  def test_require_session_token_raises_when_strict
    Parse::ACLScope.require_session_token = true
    assert_raises(Parse::ACLScope::ACLRequired) do
      Parse::ACLScope.resolve!({}, method_name: :strict_test)
    end
  end

  # ---- match_stage_for ----

  def test_match_stage_for_session_resolution
    res = Parse::ACLScope.resolve!(
      { acl_user: Parse::Pointer.new("_User", "user_abc") },
      method_name: :test,
    )
    stage = Parse::ACLScope.match_stage_for(res)
    inner = stage["$match"]
    assert inner.is_a?(Hash)
    # Should be the {$or: [{_rperm $in}, {_rperm $exists false}]} form.
    ors = inner["$or"]
    assert_equal ors.length, 2
    assert(ors.any? { |branch| branch.dig("_rperm", "$in")&.include?("user_abc") })
    assert(ors.any? { |branch| branch.dig("_rperm", "$exists") == false })
  end

  # ---- rewrite_pipeline ----

  def test_rewrite_pipeline_master_passes_through
    pipe = [{ "$lookup" => { "from" => "User", "localField" => "owner", "foreignField" => "_id", "as" => "owner" } }]
    res = Parse::ACLScope.resolve!({ master: true }, method_name: :test)
    out = Parse::ACLScope.rewrite_pipeline(pipe, res)
    assert_equal out, pipe
  end

  def test_rewrite_pipeline_session_rewrites_lookup
    pipe = [{ "$lookup" => { "from" => "User", "localField" => "owner", "foreignField" => "_id", "as" => "owner" } }]
    res = Parse::ACLScope.resolve!(
      { acl_user: Parse::Pointer.new("_User", "user_abc") },
      method_name: :test,
    )
    out = Parse::ACLScope.rewrite_pipeline(pipe, res)
    lookup = out.first["$lookup"]
    sub_pipeline = lookup["pipeline"]
    assert sub_pipeline.is_a?(Array)
    # First stage of the sub-pipeline must be the _rperm $match.
    sub_match = sub_pipeline.first["$match"]
    assert sub_match["$or"].any? { |b| b.dig("_rperm", "$in")&.include?("user_abc") }
  end

  def test_rewrite_pipeline_preserves_existing_sub_pipeline
    pipe = [{ "$lookup" => {
      "from" => "User",
      "let" => { "uid" => "$owner" },
      "pipeline" => [{ "$match" => { "$expr" => { "$eq" => ["$_id", "$$uid"] } } }],
      "as" => "owner",
    } }]
    res = Parse::ACLScope.resolve!(
      { acl_user: Parse::Pointer.new("_User", "abc") },
      method_name: :test,
    )
    out = Parse::ACLScope.rewrite_pipeline(pipe, res)
    sub = out.first["$lookup"]["pipeline"]
    # ACL match prepended; existing $expr match preserved after it.
    assert_equal sub.length, 2
    assert sub.first["$match"]["$or"]
    assert sub[1]["$match"]["$expr"]
  end

  def test_rewrite_pipeline_handles_union_with
    pipe = [{ "$unionWith" => "OtherCollection" }]
    res = Parse::ACLScope.resolve!(
      { acl_user: Parse::Pointer.new("_User", "abc") },
      method_name: :test,
    )
    out = Parse::ACLScope.rewrite_pipeline(pipe, res)
    union = out.first["$unionWith"]
    # String shorthand upgraded to {coll:, pipeline:} form.
    assert_equal union["coll"], "OtherCollection"
    assert union["pipeline"].first["$match"]
  end

  def test_rewrite_pipeline_handles_graph_lookup
    pipe = [{ "$graphLookup" => {
      "from" => "Region",
      "startWith" => "$parent",
      "connectFromField" => "parent",
      "connectToField" => "_id",
      "as" => "ancestors",
    } }]
    res = Parse::ACLScope.resolve!(
      { acl_user: Parse::Pointer.new("_User", "abc") },
      method_name: :test,
    )
    out = Parse::ACLScope.rewrite_pipeline(pipe, res)
    gl = out.first["$graphLookup"]
    assert gl["restrictSearchWithMatch"], "expected restrictSearchWithMatch on $graphLookup"
    assert gl["restrictSearchWithMatch"]["$or"]
  end

  def test_rewrite_pipeline_recurses_into_facet
    pipe = [{ "$facet" => {
      "a" => [{ "$lookup" => { "from" => "User", "localField" => "o", "foreignField" => "_id", "as" => "o" } }],
      "b" => [{ "$match" => { "x" => 1 } }],
    } }]
    res = Parse::ACLScope.resolve!(
      { acl_user: Parse::Pointer.new("_User", "abc") },
      method_name: :test,
    )
    out = Parse::ACLScope.rewrite_pipeline(pipe, res)
    facet = out.first["$facet"]
    # Branch a: its $lookup was rewritten.
    assert facet["a"].first["$lookup"]["pipeline"]
    # Branch b: untouched (no $lookup to rewrite).
    assert_equal facet["b"].first["$match"], { "x" => 1 }
  end

  # ---- redact_results! ----

  def test_redact_results_drops_subdoc_with_failing_rperm
    docs = [{ "name" => "A", "embedded" => { "_rperm" => ["role:Admin"], "data" => "hidden" } }]
    res = Parse::ACLScope.resolve!(
      { acl_user: Parse::Pointer.new("_User", "alice") },
      method_name: :test,
    )
    Parse::ACLScope.redact_results!(docs, res)
    # Sub-doc redacted because role:Admin not in alice's perms.
    assert_nil docs.first["embedded"]
  end

  def test_redact_results_keeps_subdoc_with_matching_rperm
    docs = [{ "name" => "A", "embedded" => { "_rperm" => ["*"], "data" => "public" } }]
    res = Parse::ACLScope.resolve!(
      { acl_user: Parse::Pointer.new("_User", "alice") },
      method_name: :test,
    )
    Parse::ACLScope.redact_results!(docs, res)
    assert_equal docs.first["embedded"]["data"], "public"
  end

  def test_redact_results_filters_array_elements
    docs = [{ "name" => "A", "members" => [
      { "_rperm" => ["*"], "name" => "public_user" },
      { "_rperm" => ["role:Admin"], "name" => "admin_only_user" },
      { "_rperm" => ["alice"], "name" => "alice_only" },
    ] }]
    res = Parse::ACLScope.resolve!(
      { acl_user: Parse::Pointer.new("_User", "alice") },
      method_name: :test,
    )
    Parse::ACLScope.redact_results!(docs, res)
    names = docs.first["members"].map { |m| m["name"] }
    assert_includes names, "public_user"
    assert_includes names, "alice_only"
    refute_includes names, "admin_only_user"
  end

  def test_redact_results_keeps_subdoc_with_missing_rperm
    # Missing _rperm = treated as public-readable.
    docs = [{ "name" => "A", "embedded" => { "data" => "no_rperm_field" } }]
    res = Parse::ACLScope.resolve!(
      { acl_user: Parse::Pointer.new("_User", "alice") },
      method_name: :test,
    )
    Parse::ACLScope.redact_results!(docs, res)
    assert_equal docs.first["embedded"]["data"], "no_rperm_field"
  end

  def test_redact_results_master_passes_through
    docs = [{ "name" => "A", "embedded" => { "_rperm" => ["role:Admin"], "data" => "secret" } }]
    res = Parse::ACLScope.resolve!({ master: true }, method_name: :test)
    Parse::ACLScope.redact_results!(docs, res)
    assert_equal docs.first["embedded"]["data"], "secret"
  end

  # ---- Resolution struct ----

  def test_resolution_predicates
    s = Parse::ACLScope::Resolution.new(mode: :session, permission_strings: ["*"], user_id: nil, session: nil)
    m = Parse::ACLScope::Resolution.new(mode: :master, permission_strings: nil, user_id: nil, session: nil)
    p = Parse::ACLScope::Resolution.new(mode: :public, permission_strings: ["*"], user_id: nil, session: nil)
    assert s.session?
    refute s.master?
    refute s.public?
    assert m.master?
    assert p.public?
  end

  def test_resolution_strict_role_defaults_false
    r = Parse::ACLScope::Resolution.new(
      mode: :session, permission_strings: ["role:Admin"],
      user_id: nil, session: nil,
    )
    refute r.strict_role?
  end

  def test_resolution_strict_role_when_set
    r = Parse::ACLScope::Resolution.new(
      mode: :session, permission_strings: ["role:Admin"],
      user_id: nil, session: nil, strict_role: true,
    )
    assert r.strict_role?
  end

  # ---- TRACK-CLP-6: strict_role suppresses implicit "*" grant ----

  def test_match_stage_legacy_role_resolution_includes_public
    # Synthesize the legacy (non-strict) role resolution directly so we
    # don't have to mock the _Role.first lookup. The resolution carries
    # the `["*"] + role names` perm set that `resolve_for_role` would
    # produce.
    res = Parse::ACLScope::Resolution.new(
      mode: :session,
      permission_strings: ["*", "role:Reporting"],
      user_id: nil,
      session: nil,
      strict_role: false,
    )
    stage = Parse::ACLScope.match_stage_for(res)
    in_list = stage["$match"]["$or"].first["_rperm"]["$in"]
    assert_includes in_list, "*", "legacy mode must include public grant"
    assert_includes in_list, "role:Reporting"
  end

  def test_match_stage_strict_role_drops_public_from_in_list
    # `strict_role: true` resolution intentionally OMITS "*" from
    # permission_strings; the predicate constructor must also leave
    # "*" out of the $in list (no implicit append).
    res = Parse::ACLScope::Resolution.new(
      mode: :session,
      permission_strings: ["role:Reporting"],
      user_id: nil,
      session: nil,
      strict_role: true,
    )
    stage = Parse::ACLScope.match_stage_for(res)
    in_list = stage["$match"]["$or"].first["_rperm"]["$in"]
    refute_includes in_list, "*", "strict_role: true must NOT add '*' to $in"
    assert_includes in_list, "role:Reporting"
    # The `_rperm: {$exists: false}` branch is ALWAYS present (matches
    # rows with no _rperm field, which Parse Server treats as
    # public-default). strict_role does not touch that branch.
    assert(stage["$match"]["$or"].any? { |b| b.dig("_rperm", "$exists") == false })
  end

  def test_match_stage_strict_role_with_empty_perms_fails_closed
    # Defensive: if a strict-role resolution somehow has an empty perm
    # set (e.g. the role couldn't be resolved or had no name), the
    # predicate must STILL be emitted with an empty $in — fail-closed.
    # Legacy mode early-returns nil here (no filter); strict mode must
    # not, otherwise it would fail OPEN and expose every row.
    res = Parse::ACLScope::Resolution.new(
      mode: :session,
      permission_strings: [],
      user_id: nil,
      session: nil,
      strict_role: true,
    )
    stage = Parse::ACLScope.match_stage_for(res)
    refute_nil stage, "strict_role with empty perms must still emit a $match"
    in_list = stage["$match"]["$or"].first["_rperm"]["$in"]
    assert_equal in_list, []
  end

  def test_match_stage_legacy_empty_perms_returns_nil
    # Legacy contract preserved: nil/empty perms in non-strict mode
    # means no $match is injected.
    res = Parse::ACLScope::Resolution.new(
      mode: :session,
      permission_strings: [],
      user_id: nil,
      session: nil,
      strict_role: false,
    )
    assert_nil Parse::ACLScope.match_stage_for(res)
  end

  def test_rewrite_pipeline_strict_role_drops_public_from_sub_pipeline
    # The pipeline rewriter prepends an ACL match into $lookup
    # sub-pipelines (and other join-style stages). That match must
    # also honor strict_role.
    pipe = [{ "$lookup" => {
      "from" => "Report", "localField" => "report",
      "foreignField" => "_id", "as" => "report",
    } }]
    res = Parse::ACLScope::Resolution.new(
      mode: :session,
      permission_strings: ["role:Reporting"],
      user_id: nil,
      session: nil,
      strict_role: true,
    )
    out = Parse::ACLScope.rewrite_pipeline(pipe, res)
    sub_match = out.first["$lookup"]["pipeline"].first["$match"]
    in_list = sub_match["$or"].first["_rperm"]["$in"]
    refute_includes in_list, "*"
    assert_includes in_list, "role:Reporting"
  end

  def test_resolve_strict_role_kwarg_extracted_from_options
    # `resolve!` should `delete` :strict_role off the options hash
    # even when no acl_role is present, so it doesn't leak through to
    # downstream transport. Silent on non-role paths.
    opts = { master: true, strict_role: true }
    res = Parse::ACLScope.resolve!(opts, method_name: :test)
    assert res.master?
    refute opts.key?(:strict_role), "resolve! must pop :strict_role"
  end

  # ---- TRACK-CLP-7: redact_subdocs! recursion depth bound ----

  def test_redact_subdocs_bounds_cyclic_structure
    # Build a self-referential Hash. MongoDB doesn't normally produce
    # this, but a malicious or buggy replay could. The walker must not
    # SystemStackError; it should bound at DEFAULT_REDACT_MAX_DEPTH
    # and conservatively redact the subtree.
    cycle = { "name" => "cyclic", "_rperm" => ["*"] }
    cycle["self"] = cycle
    docs = [{ "name" => "row", "embedded" => cycle }]
    res = Parse::ACLScope.resolve!(
      { acl_user: Parse::Pointer.new("_User", "alice") },
      method_name: :test,
    )
    # The bug being fixed would manifest as SystemStackError here.
    # On success, the walker returns without raising.
    assert_silent { Parse::ACLScope.redact_results!(docs, res) }
  end

  def test_redact_subdocs_explicit_depth_zero_redacts
    # Direct lever check: calling with depth: 0 must short-circuit
    # to :__redact rather than descending.
    perms_set = Set.new(["*"])
    outcome = Parse::ACLScope.send(
      :redact_subdocs!, { "a" => 1 }, perms_set, depth: 0,
    )
    assert_equal outcome, :__redact
  end

  def test_redact_subdocs_default_depth_handles_deep_nesting
    # Build a non-cyclic but deep structure (within the 32-frame
    # default) and confirm it survives the walk without redaction.
    deepest = { "leaf" => true }
    node = deepest
    20.times do
      node = { "child" => node }
    end
    docs = [{ "outer" => node }]
    res = Parse::ACLScope.resolve!(
      { acl_user: Parse::Pointer.new("_User", "alice") },
      method_name: :test,
    )
    Parse::ACLScope.redact_results!(docs, res)
    # Walk back down and confirm the leaf is intact (no _rperm in any
    # node, so nothing should have been redacted).
    cursor = docs.first["outer"]
    20.times { cursor = cursor["child"] }
    assert_equal cursor, { "leaf" => true }
  end

  # ---- Wave-3 TRACK-ACL-1: fail-closed on malformed _rperm ----
  #
  # The legacy `rperm_matches?` treated any non-Array `_rperm` (String,
  # Hash, Integer, ...) as "no _rperm at all" and let the embedded
  # sub-document through. A corrupted or attacker-controlled scalar
  # `_rperm` therefore silently bypassed redaction. The fix fails
  # CLOSED: any non-Array `_rperm` causes the sub-document to be
  # redacted, with a one-shot per-process warning so the corruption
  # surfaces rather than being absorbed.

  def test_redact_results_redacts_subdoc_with_string_rperm
    docs = [{ "name" => "A", "embedded" => { "_rperm" => "*", "data" => "looks_public" } }]
    res = Parse::ACLScope.resolve!(
      { acl_user: Parse::Pointer.new("_User", "alice") },
      method_name: :test,
    )
    _out, _err = capture_io do
      Parse::ACLScope.redact_results!(docs, res)
    end
    # String "_rperm" is malformed (Parse stores it as Array). Fail closed.
    assert_nil docs.first["embedded"],
               "non-Array _rperm must fail CLOSED, not silently permit"
  end

  def test_redact_results_redacts_subdoc_with_hash_rperm
    docs = [{ "name" => "A", "embedded" => { "_rperm" => { "$ne" => [] }, "secret" => "x" } }]
    res = Parse::ACLScope.resolve!(
      { acl_user: Parse::Pointer.new("_User", "alice") },
      method_name: :test,
    )
    _out, _err = capture_io do
      Parse::ACLScope.redact_results!(docs, res)
    end
    assert_nil docs.first["embedded"],
               "Hash _rperm (e.g. attempted operator-injection) must fail CLOSED"
  end

  def test_redact_results_drops_array_element_with_integer_rperm
    docs = [{ "members" => [
      { "_rperm" => ["*"], "name" => "ok_public" },
      { "_rperm" => 42, "name" => "corrupted_should_drop" },
    ] }]
    res = Parse::ACLScope.resolve!(
      { acl_user: Parse::Pointer.new("_User", "alice") },
      method_name: :test,
    )
    _out, _err = capture_io do
      Parse::ACLScope.redact_results!(docs, res)
    end
    names = docs.first["members"].map { |m| m["name"] }
    assert_includes names, "ok_public"
    refute_includes names, "corrupted_should_drop",
                    "Integer _rperm in array element must drop the element"
  end

  def test_malformed_rperm_warning_emitted_once_per_value_class
    docs1 = [{ "embedded" => { "_rperm" => "string1", "x" => 1 } }]
    docs2 = [{ "embedded" => { "_rperm" => "string2", "x" => 2 } }]
    docs3 = [{ "embedded" => { "_rperm" => { "k" => 1 }, "x" => 3 } }]
    res = Parse::ACLScope.resolve!(
      { acl_user: Parse::Pointer.new("_User", "alice") },
      method_name: :test,
    )
    _out, err = capture_io do
      Parse::ACLScope.redact_results!(docs1, res)
      Parse::ACLScope.redact_results!(docs2, res) # same value-class — no re-warn
      Parse::ACLScope.redact_results!(docs3, res) # different class — should warn
    end
    # Expect exactly two warnings: one for String, one for Hash.
    occurrences = err.scan(/malformed _rperm/i).length
    assert_equal 2, occurrences,
                 "expected one warning per distinct _rperm value-class, got #{occurrences}"
  end

  # ---- Wave-3 TRACK-ACL-3: cross-class CLP gate on join rewriters ----
  #
  # `rewrite_lookup` / `rewrite_union_with` / `rewrite_graph_lookup` now
  # consult {Parse::CLPScope.permits?} for the joined class with the
  # same `perms` the requesting scope holds. A scoped session that
  # cannot `find` rows of `_User` on its own surface should NOT be able
  # to laundry-list them through `$lookup: { from: "_User" }`. The
  # agent dispatcher previously held this gate alone; lifting it into
  # the shared rewriter means every mongo-direct caller (Query
  # #results_direct, Atlas Search, custom callers) benefits.

  def test_rewrite_lookup_raises_when_joined_class_clp_denies_find
    Parse::CLPScope.__cache_put("AdminOnly", clp: {
      "find" => { "role:Admin" => true },
    })
    pipe = [{ "$lookup" => {
      "from" => "AdminOnly", "localField" => "x", "foreignField" => "_id", "as" => "y",
    } }]
    res = Parse::ACLScope.resolve!(
      { acl_user: Parse::Pointer.new("_User", "alice") },
      method_name: :test,
    )
    err = assert_raises(Parse::CLPScope::Denied) do
      Parse::ACLScope.rewrite_pipeline(pipe, res)
    end
    assert_equal "AdminOnly", err.class_name
    assert_equal :find, err.operation
  end

  def test_rewrite_lookup_passes_when_joined_class_permits_find
    # `PublicJoin` was pre-populated with `find: { "*": true }` in setup.
    pipe = [{ "$lookup" => {
      "from" => "PublicJoin", "localField" => "x", "foreignField" => "_id", "as" => "y",
    } }]
    res = Parse::ACLScope.resolve!(
      { acl_user: Parse::Pointer.new("_User", "alice") },
      method_name: :test,
    )
    out = Parse::ACLScope.rewrite_pipeline(pipe, res)
    # No raise — the rewriter went through and produced a sub-pipeline.
    assert out.first["$lookup"]["pipeline"].is_a?(Array)
  end

  def test_rewrite_union_with_string_shorthand_raises_when_clp_denies
    Parse::CLPScope.__cache_put("AdminOnly", clp: {
      "find" => { "role:Admin" => true },
    })
    pipe = [{ "$unionWith" => "AdminOnly" }]
    res = Parse::ACLScope.resolve!(
      { acl_user: Parse::Pointer.new("_User", "alice") },
      method_name: :test,
    )
    assert_raises(Parse::CLPScope::Denied) do
      Parse::ACLScope.rewrite_pipeline(pipe, res)
    end
  end

  def test_rewrite_union_with_hash_form_raises_when_clp_denies
    Parse::CLPScope.__cache_put("AdminOnly", clp: {
      "find" => { "role:Admin" => true },
    })
    pipe = [{ "$unionWith" => { "coll" => "AdminOnly", "pipeline" => [{ "$match" => { "x" => 1 } }] } }]
    res = Parse::ACLScope.resolve!(
      { acl_user: Parse::Pointer.new("_User", "alice") },
      method_name: :test,
    )
    assert_raises(Parse::CLPScope::Denied) do
      Parse::ACLScope.rewrite_pipeline(pipe, res)
    end
  end

  def test_rewrite_graph_lookup_raises_when_clp_denies
    Parse::CLPScope.__cache_put("AdminOnly", clp: {
      "find" => { "role:Admin" => true },
    })
    pipe = [{ "$graphLookup" => {
      "from" => "AdminOnly", "startWith" => "$x",
      "connectFromField" => "x", "connectToField" => "_id", "as" => "y",
    } }]
    res = Parse::ACLScope.resolve!(
      { acl_user: Parse::Pointer.new("_User", "alice") },
      method_name: :test,
    )
    assert_raises(Parse::CLPScope::Denied) do
      Parse::ACLScope.rewrite_pipeline(pipe, res)
    end
  end

  def test_master_mode_bypasses_cross_class_clp_gate
    # Even if a class refuses :find for normal sessions, master mode
    # short-circuits rewrite_pipeline before the gate is ever invoked.
    # This locks in the master-key passthrough contract.
    Parse::CLPScope.__cache_put("AdminOnly", clp: {
      "find" => { "role:Admin" => true },
    })
    pipe = [{ "$lookup" => {
      "from" => "AdminOnly", "localField" => "x", "foreignField" => "_id", "as" => "y",
    } }]
    res = Parse::ACLScope.resolve!({ master: true }, method_name: :test)
    out = Parse::ACLScope.rewrite_pipeline(pipe, res)
    # Master mode = identity passthrough.
    assert_equal pipe, out
  end

  def test_nested_lookup_inside_lookup_clp_gated_at_every_level
    # An outer `$lookup` into a permitted class whose sub-pipeline
    # contains a NESTED `$lookup` into an admin-only class must still
    # raise — the requesting scope's authority doesn't elevate just
    # because the outer hop landed on a public class.
    Parse::CLPScope.__cache_put("AdminOnly", clp: {
      "find" => { "role:Admin" => true },
    })
    pipe = [{ "$lookup" => {
      "from" => "PublicJoin",
      "pipeline" => [{ "$lookup" => {
        "from" => "AdminOnly", "localField" => "x", "foreignField" => "_id", "as" => "z",
      } }],
      "as" => "y",
    } }]
    res = Parse::ACLScope.resolve!(
      { acl_user: Parse::Pointer.new("_User", "alice") },
      method_name: :test,
    )
    err = assert_raises(Parse::CLPScope::Denied) do
      Parse::ACLScope.rewrite_pipeline(pipe, res)
    end
    assert_equal "AdminOnly", err.class_name
  end
end
