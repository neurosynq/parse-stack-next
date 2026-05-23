# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit-level regression for the +Parse::User+ hydration-time +authData+
# strip. Without this defense a cross-user +Parse::User.find(other_id)+
# (or any +Parse::Query.new(User)+ result) would leak the other user's
# federated-identity tokens into the in-memory object, because Parse
# Server returns +authData+ on +GET /users/:id+ to any caller with ACL
# read on the row.
#
# The strip is in {Parse::User#apply_attributes!} and is bypassed
# inside {Parse::User.with_authdata_trust} blocks — used by the
# legitimate self-fetch paths (login/login!/session!/create/
# link_auth_data!/MFA).
class UserAuthdataStripTest < Minitest::Test
  def row_with_authdata
    {
      "className" => "_User",
      "objectId" => "abc1234567",
      "createdAt" => "2024-01-01T00:00:00.000Z",
      "updatedAt" => "2024-01-01T00:00:00.000Z",
      "username" => "alice",
      "authData" => {
        "facebook" => { "id" => "fb-id", "access_token" => "OAUTH_LEAK" },
        "anonymous" => { "id" => "anon-uuid" },
      },
    }
  end

  # --------------------------------------------------------------------
  # Default (untrusted) path: query / find / autofetch.
  # --------------------------------------------------------------------
  def test_build_strips_authdata_by_default
    user = Parse::User.build(row_with_authdata)
    refute_nil user.id, "build must still hydrate other fields"
    assert_equal "alice", user.username
    assert_nil user.auth_data,
               "authData must be stripped on the default (untrusted) hydration path"
  end

  def test_build_strips_symbol_keyed_authdata
    payload = row_with_authdata.transform_keys(&:to_sym).merge(
      authData: { facebook: { id: "fb", access_token: "LEAK" } },
    )
    user = Parse::User.build(payload)
    assert_nil user.auth_data, "symbol-keyed authData must also be stripped"
  end

  # --------------------------------------------------------------------
  # Trusted-self path: login!/session!/create/MFA wrap their build calls
  # in with_authdata_trust so authData survives.
  # --------------------------------------------------------------------
  def test_with_authdata_trust_preserves_authdata
    user = Parse::User.with_authdata_trust { Parse::User.build(row_with_authdata) }
    refute_nil user.auth_data, "trusted hydration must retain authData"
    assert_equal "OAUTH_LEAK", user.auth_data["facebook"]["access_token"]
  end

  def test_trust_does_not_leak_across_calls
    # Run a trusted hydration so its `ensure` clears the thread-local
    # back to its prior value, then run a default hydration and assert
    # the strip is back in effect — i.e. trust is correctly scoped to
    # the block, not sticky.
    Parse::User.with_authdata_trust { Parse::User.build(row_with_authdata) }
    refute Parse::User.authdata_trusted?, "trust flag must clear on block exit"

    user = Parse::User.build(row_with_authdata)
    assert_nil user.auth_data, "next non-trusted hydration must strip again"
  end

  def test_trust_restores_prior_value_on_exception
    refute Parse::User.authdata_trusted?
    assert_raises(RuntimeError) do
      Parse::User.with_authdata_trust { raise "boom" }
    end
    refute Parse::User.authdata_trusted?,
           "trust flag must be cleared even when the block raises"
  end

  def test_nested_trust_blocks_restore_to_inner_state
    Parse::User.with_authdata_trust do
      assert Parse::User.authdata_trusted?
      Parse::User.with_authdata_trust do
        assert Parse::User.authdata_trusted?
      end
      # Inner block exited; outer scope still trusted.
      assert Parse::User.authdata_trusted?,
             "nested with_authdata_trust must not clobber the outer scope on exit"
    end
    refute Parse::User.authdata_trusted?
  end

  # --------------------------------------------------------------------
  # Per-instance application path: login!'s `apply_attributes!(response.result)`
  # on an existing User instance also routes through the override and
  # so must be wrapped in trust to survive.
  # --------------------------------------------------------------------
  def test_apply_attributes_strips_authdata_outside_trust
    user = Parse::User.new
    user.apply_attributes!({
      "username" => "bob",
      "authData" => { "facebook" => { "access_token" => "LEAK" } },
    })
    assert_equal "bob", user.username
    assert_nil user.auth_data,
               "post-hoc apply_attributes! must also strip authData by default"
  end

  def test_apply_attributes_inside_trust_keeps_authdata
    user = Parse::User.new
    Parse::User.with_authdata_trust do
      user.apply_attributes!({
        "username" => "bob",
        "authData" => { "facebook" => { "id" => "fb", "access_token" => "KEEP" } },
      })
    end
    refute_nil user.auth_data
    assert_equal "KEEP", user.auth_data["facebook"]["access_token"]
  end

  # --------------------------------------------------------------------
  # The strip must not be a destructive mutation of the caller's hash
  # — server JSON often gets logged or re-used by callers and silently
  # dropping a key in place would surprise them.
  # --------------------------------------------------------------------
  def test_strip_does_not_mutate_caller_hash
    payload = {
      "className" => "_User",
      "objectId" => "abc1234567",
      "username" => "alice",
      "authData" => { "facebook" => { "id" => "fb" } },
    }
    Parse::User.build(payload)
    assert payload.key?("authData"),
           "build must not mutate the caller's hash when stripping authData"
  end
end
