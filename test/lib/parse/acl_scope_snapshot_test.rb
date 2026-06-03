require_relative "../../test_helper"
require_relative "../../support/snapshot_helper"
require "minitest/autorun"

# Snapshot regression coverage for the `_rperm`-injection $match stage that
# Parse::ACLScope.match_stage_for emits for mongo-direct queries. This is the
# only layer between a scoped agent and unfiltered MongoDB results, so any
# silent reshape is a security issue. Snapshots normalize the $in array order
# (permission strings come from an unordered Set) and ObjectId-shaped IDs.
class ACLScopeSnapshotTest < Minitest::Test
  GROUP = "acl_scope".freeze

  def resolution(mode:, permission_strings:, user_id: nil, strict_role: false)
    Parse::ACLScope::Resolution.new(
      mode: mode,
      permission_strings: permission_strings,
      user_id: user_id,
      session: nil,
      strict_role: strict_role,
    )
  end

  def stage_for(res)
    Parse::ACLScope.match_stage_for(res)
  end

  def test_anonymous_public_only
    res = resolution(mode: :public, permission_strings: ["*"])
    assert_snapshot(stage_for(res), name: "anonymous_public_only", group: GROUP)
  end

  def test_user_with_roles
    res = resolution(
      mode: :session,
      # Deliberately unsorted to exercise the normalizer's $in sort.
      permission_strings: ["role:Editor", "u_alice", "*", "role:Admin"],
      user_id: "u_alice",
    )
    assert_snapshot(stage_for(res), name: "user_with_roles", group: GROUP)
  end

  def test_role_only_non_strict
    res = resolution(
      mode: :role,
      permission_strings: ["*", "role:reporting"],
      strict_role: false,
    )
    assert_snapshot(stage_for(res), name: "role_only_non_strict", group: GROUP)
  end

  def test_role_only_strict
    # Strict-role MUST omit the "*" public grant and still emit a $match even
    # if perms is empty (fail-closed). The $exists: false branch covers
    # legacy rows with no _rperm field at all.
    res = resolution(
      mode: :role,
      permission_strings: ["role:reporting"],
      strict_role: true,
    )
    stage = stage_for(res)
    refute_includes JSON.generate(stage), '"*"',
                    "strict_role: true must NOT include the public '*' grant"
    assert_snapshot(stage, name: "role_only_strict", group: GROUP)
  end

  def test_role_only_strict_empty_fail_closed
    res = resolution(
      mode: :role,
      permission_strings: [],
      strict_role: true,
    )
    stage = stage_for(res)
    # Defensive belt-and-suspenders: an empty $in is the only thing that
    # makes strict-mode actually fail closed; a snapshot mismatch alone
    # would catch a wider $in but not a regression that wholesale skipped
    # the $match.
    assert stage.is_a?(Hash), "strict_role: true MUST emit a $match stage even when perms is empty"
    refute_includes JSON.generate(stage), '"*"',
                    "strict_role: true must NOT include the public '*' grant"
    assert_snapshot(stage, name: "role_only_strict_empty", group: GROUP)
  end

  def test_master_emits_no_stage
    res = resolution(mode: :master, permission_strings: nil)
    # nil snapshot = "no injection" — pin that.
    assert_snapshot({ "stage" => stage_for(res) }, name: "master_no_injection", group: GROUP)
  end

  def test_nil_resolution_emits_no_stage
    assert_snapshot({ "stage" => stage_for(nil) }, name: "nil_resolution", group: GROUP)
  end

  def test_legacy_empty_perms_skips_injection
    # Non-strict + empty perms is the legacy "nothing to inject" path —
    # match_stage_for returns nil rather than a wide-open $match. This is
    # FAIL-OPEN by design and is gated upstream to legacy callers; the
    # snapshot enshrines that contract so a refactor can't silently widen
    # the surface that hits this branch.
    res = resolution(mode: :public, permission_strings: [], strict_role: false)
    assert_snapshot({ "stage" => stage_for(res) }, name: "legacy_empty_perms", group: GROUP)
  end

  # --- additional coverage ------------------------------------------------

  def test_user_only_no_roles
    # Authenticated session whose user has no role memberships at all —
    # the common case for new accounts. Perm set is {"*", userId}.
    res = resolution(
      mode: :session,
      permission_strings: ["*", "u_alice"],
      user_id: "u_alice",
    )
    assert_snapshot(stage_for(res), name: "user_only_no_roles", group: GROUP)
  end

  def test_session_token_mode
    # Distinct from acl_user: — the session-token branch produces mode:
    # :session. Snapshot it independently to pin the contract.
    res = resolution(
      mode: :session,
      permission_strings: ["*", "u_bob", "role:Editor"],
      user_id: "u_bob",
    )
    assert_snapshot(stage_for(res), name: "session_token_mode", group: GROUP)
  end

  def test_strict_role_with_user_perms
    # Strict mode + a perm set that mixes user and role grants. Strict must
    # drop the "*" public grant while keeping every other perm verbatim.
    res = resolution(
      mode: :role,
      permission_strings: ["u_alice", "role:scope:reporting"],
      strict_role: true,
    )
    stage = stage_for(res)
    refute_includes JSON.generate(stage), '"*"',
                    "strict_role: true must NOT include the public '*' grant"
    assert_snapshot(stage, name: "strict_role_mixed_user_perms", group: GROUP)
  end

  def test_role_names_with_special_chars
    # Role names with colons / dots / dashes / asterisks must pass through
    # verbatim — `$in` is an exact-match operator so the literal string is
    # what protects the row. A snapshot pins that the SDK does NOT regex-
    # escape or otherwise mangle these.
    res = resolution(
      mode: :role,
      permission_strings: [
        "*",
        "role:scope:reporting",
        "role:team.alpha",
        "role:foo-bar",
        "role:weird*name",
      ],
      strict_role: false,
    )
    assert_snapshot(stage_for(res), name: "role_names_special_chars", group: GROUP)
  end

  def test_duplicate_perms_dedupe_or_preserved
    # The Set-backed resolver should dedupe, but if the caller hands us an
    # Array with duplicates we want to see the post-normalization shape so
    # a regression to "Array reaches `$in` verbatim" is loud.
    res = resolution(
      mode: :session,
      permission_strings: ["*", "u_alice", "u_alice", "role:Admin", "role:Admin"],
      user_id: "u_alice",
    )
    assert_snapshot(stage_for(res), name: "duplicate_perms", group: GROUP)
  end
end
