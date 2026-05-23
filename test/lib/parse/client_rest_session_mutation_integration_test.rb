require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"
require "securerandom"

# Companion to {ClientRestLogoutAllIntegrationTest}. Covers the
# server-side half of the +_Session+ defense: a logged-in user under
# client mode (no master key) MUST NOT be able to read, mutate, or
# delete another user's +_Session+ rows. Parse Server enforces this
# natively via per-row ACL on +_Session+ (auto-set to owner-only on
# session creation), but the SDK's session-scoped query plumbing has
# to plumb the caller's token through correctly for that enforcement
# to fire — without the token Parse Server treats the request as
# unauthenticated, with the wrong token it fails closed.
#
# These tests do not pin Parse Server's exact response code (some
# versions 404 cross-user fetches, others return empty, others 403).
# The load-bearing invariant is "victim's _Session row is NOT visible
# or mutable from the attacker's session" — observed by counting the
# results / asserting the row remains intact.
class ClientRestSessionMutationIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
    @alice, @alice_pw = seed_client_user("smut_alice")
    @bob, @bob_pw = seed_client_user("smut_bob")
  end

  # --------------------------------------------------------------------
  # Bob queries _Session under his own token. Must NOT see Alice's
  # session rows. Parse Server enforces this via the row-level ACL
  # auto-set on _Session creation (owner-only read/write).
  # --------------------------------------------------------------------
  def test_session_query_under_bob_does_not_return_alice_sessions
    as_client do
      alice = Parse::User.login(@alice.username, @alice_pw)
      bob = Parse::User.login(@bob.username, @bob_pw)

      alice_pointer = Parse::User.pointer(alice.id)
      Parse.with_session(bob.session_token) do
        results = Parse::Session.query(user: alice_pointer).all
        assert results.empty?,
               "Bob's session-scoped _Session query must not return Alice's rows " \
               "(got #{results.size}: #{results.map(&:id).inspect})"
      end
    end
  end

  # --------------------------------------------------------------------
  # Bob's call to Parse::Session.for_user(alice).all under his own
  # session is the same query pattern used by Alice#sessions but with
  # the wrong caller. Must come back empty.
  # --------------------------------------------------------------------
  def test_session_for_user_under_bob_does_not_leak_alice_sessions
    as_client do
      alice = Parse::User.login(@alice.username, @alice_pw)
      bob = Parse::User.login(@bob.username, @bob_pw)

      Parse.with_session(bob.session_token) do
        results = Parse::Session.for_user(alice).all
        assert results.empty?,
               "Bob must not see Alice's sessions via Parse::Session.for_user " \
               "(got #{results.size})"
      end

      # Sanity: Alice's session(s) still exist when queried under her
      # own token. Otherwise the empty result above is vacuous.
      Parse.with_session(alice.session_token) do
        mine = Parse::Session.for_user(alice).all
        refute mine.empty?,
               "Alice's own session query must still return her rows"
      end
    end
  end

  # --------------------------------------------------------------------
  # Cross-user DELETE: Bob attempts to delete a known Alice session
  # objectId. Must fail (Parse Server rejects on ACL). The Alice
  # session remains intact when re-checked under her own token.
  #
  # This is the targeted equivalent of the +logout_all!+ ATO vector:
  # if the SDK or Parse Server let a non-owner delete _Session rows
  # by objectId, an attacker who learned the row id (or who could
  # enumerate them) could mass-revoke other users' sessions.
  # --------------------------------------------------------------------
  def test_cross_user_session_delete_under_bob_is_denied
    as_client do
      alice = Parse::User.login(@alice.username, @alice_pw)
      bob = Parse::User.login(@bob.username, @bob_pw)

      # Find Alice's session row id under Alice's auth.
      alice_session = Parse.with_session(alice.session_token) do
        Parse::Session.for_user(alice).all.first
      end
      refute_nil alice_session, "precondition: Alice must have at least one session row"
      alice_row_id = alice_session.id

      # Bob attempts to destroy it. Parse Server may raise an
      # authorization error or return error?; both are acceptable as
      # long as the row is NOT actually deleted.
      Parse.with_session(bob.session_token) do
        begin
          Parse.client.delete_object(Parse::Model::CLASS_SESSION, alice_row_id)
        rescue Parse::Error
          # Expected — server fails closed on cross-user _Session DELETE.
        end
      end

      # Verify the row is still there from Alice's perspective.
      Parse.with_session(alice.session_token) do
        still_there = Parse::Session.for_user(alice).all.map(&:id)
        assert_includes still_there, alice_row_id,
                        "Alice's session row must NOT have been deleted by Bob's call"
      end
    end
  end

  # --------------------------------------------------------------------
  # Cross-user UPDATE: same row, attempt to mutate +installationId+
  # (or any property) as Bob. Must be denied; the row must remain
  # unchanged when re-fetched under Alice.
  # --------------------------------------------------------------------
  def test_cross_user_session_update_under_bob_is_denied
    as_client do
      alice = Parse::User.login(@alice.username, @alice_pw)
      bob = Parse::User.login(@bob.username, @bob_pw)

      alice_session = Parse.with_session(alice.session_token) do
        Parse::Session.for_user(alice).all.first
      end
      refute_nil alice_session
      alice_row_id = alice_session.id
      original_installation = alice_session.installation_id

      Parse.with_session(bob.session_token) do
        begin
          Parse.client.update_object(
            Parse::Model::CLASS_SESSION,
            alice_row_id,
            { installationId: "bob-was-here-#{SecureRandom.hex(4)}" },
          )
        rescue Parse::Error
          # Expected.
        end
      end

      Parse.with_session(alice.session_token) do
        refetched = Parse::Session.for_user(alice).all.find { |s| s.id == alice_row_id }
        refute_nil refetched, "Alice's session row must still exist"
        assert refetched.installation_id == original_installation,
               "Alice's session row installationId must not have been mutated by Bob " \
               "(before: #{original_installation.inspect}, after: #{refetched.installation_id.inspect})"
      end
    end
  end
end
