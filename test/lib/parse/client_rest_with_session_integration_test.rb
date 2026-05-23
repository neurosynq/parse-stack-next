require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"
require "securerandom"

# Covers the fiber-local ambient session token introduced by
# `Parse.with_session(token) { ... }`, the `Parse::User#with_session`
# instance sugar, and the process-wide `Parse.client_mode` flag.
#
# Goal: prove that an SDK consumer can scope a region of code to a
# logged-in user once at the top, then make plain CRUD calls without
# threading `session_token:` through every call site — and prove the
# escape hatches (explicit kwarg, nested block, master-key opt-in)
# still work.
class ClientWithSessionDoc < Parse::Object
  parse_class "ClientWithSessionDoc"
  acl_policy :owner_else_private
  property :title, :string
end

class ClientRestWithSessionIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
    @alice, @alice_pw = seed_client_user("ws_alice")
    @bob,   @bob_pw   = seed_client_user("ws_bob")
  end

  def teardown
    # Clear any ambient session left behind by an imperative `Parse.login`
    # whose corresponding `Parse.logout` never ran (test raised mid-way).
    # `Parse.with_session` blocks self-cleanup via `ensure`, so this is
    # only paranoia for the imperative path.
    Parse.logout(revoke: false) if Parse.current_session_token
    Parse.client_mode = false
    super
  end

  # --------------------------------------------------------------------
  # 1. Ambient token flows through to a plain class-level read with no
  #    explicit session_token: kwarg on the call.
  # --------------------------------------------------------------------
  def test_ambient_session_flows_through_to_class_read
    doc_id = nil
    as_client do
      alice = Parse::User.login!(@alice.username, @alice_pw)
      Parse.with_session(alice) do
        doc = ClientWithSessionDoc.new(title: "alice's row", as: alice)
        assert doc.save, "save under ambient session must succeed"
        @test_context.track(doc)
        doc_id = doc.id

        # Plain class-level read — NO session_token: kwarg. Must pick up
        # the ambient and return the row (which would be invisible to an
        # anonymous read under :owner_else_private).
        fetched = ClientWithSessionDoc.find(doc_id)
        refute_nil fetched, "ambient session must reach a plain `.find` call"
        assert_equal "alice's row", fetched.title
      end
    end
  end

  # --------------------------------------------------------------------
  # 2. Ambient does NOT leak outside the block — a read after the block
  #    exits is anonymous again and gets denied.
  # --------------------------------------------------------------------
  def test_ambient_session_does_not_leak_outside_block
    doc_id = nil
    as_client do
      alice = Parse::User.login!(@alice.username, @alice_pw)
      Parse.with_session(alice) do
        doc = ClientWithSessionDoc.new(title: "scoped", as: alice)
        assert doc.save
        @test_context.track(doc)
        doc_id = doc.id
      end

      assert_nil Parse.current_session_token,
                 "ambient must clear on block exit"

      # Same process, same client — but no ambient. The owner-private row
      # is not visible anonymously.
      after = ClientWithSessionDoc.find(doc_id)
      assert_nil after, "owner-private row must be invisible without ambient session"
    end
  end

  # --------------------------------------------------------------------
  # 3. Nested with_session blocks restore the prior token on exit.
  # --------------------------------------------------------------------
  def test_nested_with_session_restores_outer_token_on_exit
    as_client do
      alice = Parse::User.login!(@alice.username, @alice_pw)
      bob   = Parse::User.login!(@bob.username,   @bob_pw)

      Parse.with_session(alice) do
        assert_equal alice.session_token, Parse.current_session_token
        Parse.with_session(bob) do
          assert_equal bob.session_token, Parse.current_session_token
        end
        assert_equal alice.session_token, Parse.current_session_token,
                     "outer ambient must be restored after nested block"
      end
      assert_nil Parse.current_session_token
    end
  end

  # --------------------------------------------------------------------
  # 4. Explicit session_token: kwarg on a call wins over ambient.
  # --------------------------------------------------------------------
  def test_explicit_kwarg_wins_over_ambient
    doc_id = nil
    as_client do
      alice = Parse::User.login!(@alice.username, @alice_pw)
      bob   = Parse::User.login!(@bob.username,   @bob_pw)

      # Alice writes a private row.
      Parse.with_session(alice) do
        doc = ClientWithSessionDoc.new(title: "alice-only", as: alice)
        assert doc.save
        @test_context.track(doc)
        doc_id = doc.id
      end

      # Inside a Bob-ambient block, ask for alice's row but explicitly
      # pass alice's token. The explicit kwarg must win.
      Parse.with_session(bob) do
        explicit = ClientWithSessionDoc.find(doc_id, session_token: alice.session_token)
        refute_nil explicit, "explicit session_token: kwarg must override ambient"
        assert_equal "alice-only", explicit.title

        # And the ambient path (no kwarg) must remain bob-scoped: bob
        # cannot see alice's private row.
        ambient = ClientWithSessionDoc.find(doc_id)
        assert_nil ambient, "ambient must remain scoped to bob (no leakage from explicit call)"
      end
    end
  end

  # --------------------------------------------------------------------
  # 5. User#with_session instance sugar uses the user's session_token.
  # --------------------------------------------------------------------
  def test_user_with_session_instance_sugar
    as_client do
      alice = Parse::User.login!(@alice.username, @alice_pw)
      doc_id = nil
      alice.with_session do
        assert_equal alice.session_token, Parse.current_session_token
        doc = ClientWithSessionDoc.new(title: "via user#with_session", as: alice)
        assert doc.save
        @test_context.track(doc)
        doc_id = doc.id
      end
      assert_nil Parse.current_session_token, "instance sugar must restore on exit"

      alice.with_session do
        fetched = ClientWithSessionDoc.find(doc_id)
        refute_nil fetched
        assert_equal "via user#with_session", fetched.title
      end
    end
  end

  # --------------------------------------------------------------------
  # 6. User#with_session on an unauthenticated user fails closed.
  # --------------------------------------------------------------------
  def test_user_with_session_without_token_raises
    u = Parse::User.new
    u.id = "fakeobjid01"
    err = assert_raises(Parse::Error::AuthenticationError) do
      u.with_session { :unreached }
    end
    assert_match(/requires an authenticated session/, err.message)
  end

  # --------------------------------------------------------------------
  # 7. with_session(nil) clears the ambient inside the block — useful
  #    for one anonymous call within a scoped region.
  # --------------------------------------------------------------------
  def test_with_session_nil_clears_ambient_for_block
    as_client do
      alice = Parse::User.login!(@alice.username, @alice_pw)
      Parse.with_session(alice) do
        assert_equal alice.session_token, Parse.current_session_token
        Parse.with_session(nil) do
          assert_nil Parse.current_session_token,
                     "with_session(nil) must blank the ambient inside the block"
        end
        assert_equal alice.session_token, Parse.current_session_token,
                     "outer ambient must restore after nil block"
      end
    end
  end

  # --------------------------------------------------------------------
  # 8. Imperative `Parse.login` / `Parse.logout` for REPL / Rake-console
  #    use — sets the ambient persistently for the current fiber, no
  #    block required.
  # --------------------------------------------------------------------
  def test_imperative_login_logout_for_console
    as_client do
      user = Parse.login(@alice.username, @alice_pw)
      assert_equal @alice.username, user.username
      assert_equal user.session_token, Parse.current_session_token
      assert_equal user.id, Parse.current_user&.id

      # No block, no kwarg — subsequent calls should be auth-scoped.
      doc = ClientWithSessionDoc.new(title: "console-style", as: user)
      assert doc.save, "save under imperative login must succeed"
      @test_context.track(doc)
      doc_id = doc.id

      fetched = ClientWithSessionDoc.find(doc_id)
      refute_nil fetched, "ambient set by Parse.login must reach plain reads"
      assert_equal "console-style", fetched.title

      Parse.logout(revoke: false)  # avoid noisy revoke if server doesn't like the token shape
      assert_nil Parse.current_session_token, "logout must clear ambient"
      assert_nil Parse.current_user,          "logout must clear current_user"

      # After logout, owner-private row is no longer visible.
      after = ClientWithSessionDoc.find(doc_id)
      assert_nil after, "post-logout read must be anonymous and see nothing"
    end
  end

  # --------------------------------------------------------------------
  # 9. Child fibers inherit a COPY of parent's ambient (per Ruby 3.2+
  #    Fiber.storage semantics), but mutations in the child do NOT
  #    escape back to the parent. A new Thread's root fiber ALSO
  #    inherits from the parent fiber at creation time (Ruby 3.2+),
  #    and mutations there likewise stay local to the thread. This is
  #    why `Parse::Object.find`'s parallel path snapshots ambient
  #    before spawning workers — to lock in the value the caller
  #    intended at call time, regardless of later block transitions.
  # --------------------------------------------------------------------
  def test_ambient_fiber_storage_semantics
    inside_outer = nil
    inside_child_fiber = nil
    after_child_in_parent = nil
    inside_thread = nil
    after_thread_in_parent = nil

    Parse.with_session("outer-tok") do
      inside_outer = Parse.current_session_token

      child = Fiber.new do
        inside_child_fiber = Parse.current_session_token
        # Mutation inside child fiber must NOT leak back to parent.
        Fiber[Parse::SESSION_TOKEN_STATE_KEY] = "child-mutation"
      end
      child.resume
      after_child_in_parent = Parse.current_session_token

      # A separate thread inherits the parent fiber's storage at
      # creation, but mutations made inside the thread stay there.
      Thread.new do
        inside_thread = Parse.current_session_token
        Fiber[Parse::SESSION_TOKEN_STATE_KEY] = "thread-mutation"
      end.join
      after_thread_in_parent = Parse.current_session_token
    end

    assert_equal "outer-tok", inside_outer
    assert_equal "outer-tok", inside_child_fiber,
                 "child Fiber must inherit parent's ambient at creation time"
    assert_equal "outer-tok", after_child_in_parent,
                 "child fiber's mutation must not leak back to parent"
    assert_equal "outer-tok", inside_thread,
                 "new Thread's root fiber inherits parent fiber storage (Ruby 3.2+)"
    assert_equal "outer-tok", after_thread_in_parent,
                 "thread's mutation must not leak back to parent"
  end
end
