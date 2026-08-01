# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# The hazard this closes was created by making authorization per-client while
# the MongoDB connection stayed process-global.
#
# Before 5.7 both were global, so they were at least consistently wrong
# together. Now `client.authorization` resolves a session token against that
# client's own Parse application, while `Parse::MongoDB` still holds one URI,
# one database, and one driver client chosen by whoever called `configure`. A
# secondary client would resolve its token correctly, build a correct `_rperm`
# allow-set for a user of ITS application, and then run the resulting pipeline
# against the other application's database. Nothing about that looks like a
# failure; it looks like a query that returned few rows.
class MongoDBClientBindingTest < Minitest::Test
  def setup
    @bound = Parse::MongoDB.instance_variable_get(:@bound_app_scope)
    @observed = Parse::MongoDB.instance_variable_get(:@observed_app_scopes)
    # Every test starts having seen nothing. The observed set decides whether
    # an unidentified caller is ambiguous, so leaking it between tests makes
    # results depend on run order.
    Parse::MongoDB.instance_variable_set(:@observed_app_scopes, nil)
  end

  def teardown
    Parse::MongoDB.instance_variable_set(:@bound_app_scope, @bound)
    Parse::MongoDB.instance_variable_set(:@observed_app_scopes, @observed)
  end

  def bind_to(app_id, server_url = "https://a.example.com/parse")
    scope = app_id.nil? ? nil : Parse::MongoDB.app_scope_for(FakeClient.new(app_id, server_url))
    Parse::MongoDB.instance_variable_set(:@bound_app_scope, scope)
  end

  FakeClient = Struct.new(:application_id, :server_url) do
    def initialize(app_id, server = "https://a.example.com/parse")
      super(app_id, server)
    end
  end

  def test_matching_application_passes
    bind_to("appA")
    Parse::MongoDB.verify_client!(FakeClient.new("appA"))
  end

  def test_mismatched_application_fails_closed
    bind_to("appA")
    error = assert_raises(Parse::MongoDB::ClientMismatch) do
      Parse::MongoDB.verify_client!(FakeClient.new("appB"))
    end
    assert_includes error.message, "appA"
    assert_includes error.message, "appB"
  end

  # A connection configured before this guard existed, or in a process that
  # set up Mongo before Parse, records no binding. There is nothing to compare
  # against, so the call proceeds rather than breaking every such deployment.
  def test_no_binding_recorded_permits_the_call
    bind_to(nil)
    Parse::MongoDB.verify_client!(FakeClient.new("appB"))
  end

  # Master-mode and public-fallback resolutions can be produced in a process
  # that never called Parse.setup, so they carry no client. An unidentifiable
  # caller cannot be checked, and refusing it would break paths that worked
  # before authorization was client-scoped at all.
  # One application seen, so an unidentified caller is unambiguous. This is
  # every single-application deployment, and master-mode or public-fallback
  # resolutions produced before Parse.setup land here.
  def test_unidentifiable_caller_permits_the_call_with_one_application
    bind_to("appA")
    Parse::MongoDB.verify_client!(nil)
    Parse::MongoDB.verify_client!(FakeClient.new(nil))
    Parse::MongoDB.verify_client!(Object.new)
  end

  # Once a SECOND application has been seen, an unidentified caller is a real
  # ambiguity. Allowing it meant any call path that forgot to forward its
  # client silently read whichever database happened to be bound, which made
  # the completeness of that plumbing the only thing standing between two
  # applications. It fails closed instead.
  def test_unidentifiable_caller_is_refused_once_two_applications_are_seen
    bind_to("appA")
    Parse::MongoDB.verify_client!(FakeClient.new("appA"))
    assert_raises(Parse::MongoDB::ClientMismatch) do
      Parse::MongoDB.verify_client!(FakeClient.new("appB"))
    end

    error = assert_raises(Parse::MongoDB::ClientMismatch) do
      Parse::MongoDB.verify_client!(nil)
    end
    assert_includes error.message, "no identifiable client"
  end

  # Configuring MongoDB before Parse.setup recorded no binding, and a nil
  # binding disabled the check permanently. That is the most natural boot
  # order, so it silently opted the whole process out. Binding now happens on
  # first identified use instead.
  def test_binds_lazily_when_configure_ran_before_any_client_existed
    Parse::MongoDB.instance_variable_set(:@bound_app_scope, nil)

    Parse::MongoDB.verify_client!(FakeClient.new("appA"))
    refute_nil Parse::MongoDB.instance_variable_get(:@bound_app_scope),
               "the first identified caller must establish the binding"

    assert_raises(Parse::MongoDB::ClientMismatch) do
      Parse::MongoDB.verify_client!(FakeClient.new("appB"))
    end
  end

  # REPRODUCED P0: lazy binding used `@bound_app_scope ||= caller_scope`, so
  # whoever called first won. Configure MongoDB before Parse, install default
  # client A, then make the first direct request explicitly as B, and the
  # connection bound itself to B and read A's database without complaint.
  # Ownership decides the binding, never call order.
  def test_first_caller_cannot_claim_the_binding_away_from_the_owner
    Parse::MongoDB.instance_variable_set(:@bound_app_scope, nil)
    owner = FakeClient.new("appA")

    Parse::MongoDB.stub(:default_client_or_nil, owner) do
      # B arrives first and must NOT get to define the binding.
      assert_raises(Parse::MongoDB::ClientMismatch) do
        Parse::MongoDB.verify_client!(FakeClient.new("appB"))
      end
      # The owner still matches, proving the binding followed ownership.
      Parse::MongoDB.verify_client!(FakeClient.new("appA"))
    end
  end

  # With no default client at all there is no ownership to read, so the first
  # caller is the only signal available and nothing can conflict with it.
  def test_first_caller_binds_only_when_there_is_no_owner
    Parse::MongoDB.instance_variable_set(:@bound_app_scope, nil)
    Parse::MongoDB.stub(:default_client_or_nil, nil) do
      Parse::MongoDB.verify_client!(FakeClient.new("appB"))
      assert_raises(Parse::MongoDB::ClientMismatch) do
        Parse::MongoDB.verify_client!(FakeClient.new("appA"))
      end
    end
  end

  # REPRODUCED P0: `collection` passed `authorizing_client || default_client`,
  # so a call site that forgot to forward its client was presented as the
  # default and passed against a default-bound database. That made the
  # fail-closed branch unreachable and contradicted the documented behavior.
  def test_a_forgotten_client_is_unidentified_not_the_default
    Parse::MongoDB.instance_variable_set(:@bound_app_scope, nil)
    owner = FakeClient.new("appA")

    Parse::MongoDB.stub(:default_client_or_nil, owner) do
      Parse::MongoDB.verify_client!(owner)
      # A second application is now in play.
      assert_raises(Parse::MongoDB::ClientMismatch) do
        Parse::MongoDB.verify_client!(FakeClient.new("appB"))
      end
      # A call that forgot to forward its client must NOT be upgraded to the
      # default and waved through.
      error = assert_raises(Parse::MongoDB::ClientMismatch) do
        Parse::MongoDB.verify_client!(nil)
      end
      assert_includes error.message, "no identifiable client"
    end
  end

  # The owner counts toward the observed set even when it never issues a
  # direct read itself. Otherwise a process where only the SECOND application
  # ever identifies itself sees one scope and waves unidentified callers past.
  def test_the_owner_counts_toward_the_ambiguity_check
    Parse::MongoDB.instance_variable_set(:@bound_app_scope, nil)

    Parse::MongoDB.stub(:default_client_or_nil, FakeClient.new("appA")) do
      assert_raises(Parse::MongoDB::ClientMismatch) do
        Parse::MongoDB.verify_client!(FakeClient.new("appB"))
      end
      assert_raises(Parse::MongoDB::ClientMismatch) do
        Parse::MongoDB.verify_client!(nil)
      end
    end
  end

  # A default client installed AFTER the connection fell back to binding on an
  # explicit caller must still count toward the ambiguity check. Only looking
  # at the owner while unbound meant the observed set held one scope forever,
  # so unidentified callers looked unambiguous and went through to the wrong
  # database.
  def test_a_default_client_installed_after_binding_is_still_observed
    Parse::MongoDB.instance_variable_set(:@bound_app_scope, nil)

    # No owner yet, so B's explicit call establishes the binding.
    Parse::MongoDB.stub(:default_client_or_nil, nil) do
      Parse::MongoDB.verify_client!(FakeClient.new("appB"))
    end

    # A shows up afterwards. An unidentified caller is now ambiguous.
    Parse::MongoDB.stub(:default_client_or_nil, FakeClient.new("appA")) do
      assert_raises(Parse::MongoDB::ClientMismatch) do
        Parse::MongoDB.verify_client!(nil)
      end
    end
  end

  # A resolution that cannot name its client is an unidentified caller, not a
  # crash. Doubles and caller-supplied stand-ins hit this.
  def test_client_of_tolerates_a_resolution_without_a_client
    shape = Object.new
    assert_nil Parse::ACLScope.client_of(shape)
    assert_nil Parse::ACLScope.client_of(nil)
  end

  # Application ids are not globally unique. The same id is routinely reused
  # across a staging and a production deployment of one app, which is exactly
  # the pair most likely to be configured together in a developer process.
  # Comparing ids alone would call that a match and let a staging client
  # authorize a read of the production database.
  def test_same_app_id_on_a_different_server_is_a_mismatch
    bind_to("appA", "https://prod.example.com/parse")
    error = assert_raises(Parse::MongoDB::ClientMismatch) do
      Parse::MongoDB.verify_client!(FakeClient.new("appA", "https://staging.example.com/parse"))
    end
    assert_includes error.message, "staging.example.com"
    assert_includes error.message, "prod.example.com"
  end

  def test_same_app_id_on_the_same_server_matches
    bind_to("appA", "https://prod.example.com/parse")
    Parse::MongoDB.verify_client!(FakeClient.new("appA", "https://prod.example.com/parse"))
  end

  # The scope joins with a NUL byte, which must never reach an operator.
  def test_message_renders_the_scope_readably
    bind_to("appA", "https://prod.example.com/parse")
    error = assert_raises(Parse::MongoDB::ClientMismatch) do
      Parse::MongoDB.verify_client!(FakeClient.new("appB"))
    end
    refute_includes error.message, "\u0000"
  end

  # The message has to say what to do about it. A bare "mismatch" would send
  # an operator looking for a bug in their query.
  def test_message_names_the_remedy
    bind_to("appA")
    error = assert_raises(Parse::MongoDB::ClientMismatch) do
      Parse::MongoDB.verify_client!(FakeClient.new("appB"))
    end
    assert_includes error.message, "REST"
  end

  # ACLScope must label every resolution with its client, or the guard above
  # has nothing to check and silently permits everything.
  def test_every_resolution_carries_its_client
    modes = [
      [{ master: true }, :master],
      [{}, :public],
    ]
    modes.each do |kwargs, expected_mode|
      resolution = Parse::ACLScope.resolve!(kwargs.dup, method_name: :aggregate)
      assert_equal expected_mode, resolution.mode
      assert resolution.respond_to?(:client),
             "Resolution must carry the client so MongoDB.verify_client! can check it"
    end
  end

  # The kwarg must be consumed, not forwarded to the driver, which would
  # reject it as an unknown aggregate option.
  def test_client_kwarg_is_popped_from_the_options_hash
    options = { master: true, client: nil, max_time_ms: 500 }
    Parse::ACLScope.resolve!(options, method_name: :aggregate)
    refute options.key?(:client), "client: must be consumed like the other auth kwargs"
    assert_equal 500, options[:max_time_ms], "non-auth options must survive"
  end

  # An explicit client: must reach the Resolution, or the guard has nothing to
  # compare and every call silently resolves through Parse.client instead.
  # This was the gap that made the guard near-vacuous when it first landed:
  # the check existed, but no entry point could deliver a second client to it.
  def test_explicit_client_reaches_the_resolution
    other = FakeClient.new("appB")
    other.define_singleton_method(:authorization) do
      Struct.new(:client).new(self)
    end

    resolution = Parse::ACLScope.resolve!({ master: true, client: other },
                                          method_name: :aggregate)
    assert_same other, resolution.client
  end

  # And the guard must then refuse it. Together with the test above this is
  # the whole contract: a second client's authorization cannot be used to read
  # the database another application's connection is bound to.
  def test_a_second_clients_resolution_is_refused_against_a_foreign_binding
    bind_to("appA")
    other = FakeClient.new("appB")
    other.define_singleton_method(:authorization) do
      Struct.new(:client).new(self)
    end

    resolution = Parse::ACLScope.resolve!({ master: true, client: other },
                                          method_name: :aggregate)
    assert_raises(Parse::MongoDB::ClientMismatch) do
      Parse::MongoDB.verify_client!(resolution.client)
    end
  end

  # Every public direct-read entry point has to accept the kwarg, or the
  # threading is only half done and the gap reopens on whichever one was
  # missed.
  def test_every_direct_entry_point_accepts_client
    {
      Parse::Query => %i[results_direct count_direct distinct_direct distinct_direct_pointers],
      Parse::MongoDB.singleton_class => %i[aggregate],
    }.each do |owner, methods|
      methods.each do |name|
        keywords = owner.instance_method(name).parameters
                        .select { |type, _| %i[key keyreq].include?(type) }
                        .map(&:last)
        assert_includes keywords, :client,
                        "#{owner}##{name} must accept client: or it cannot be scoped"
      end
    end
  end
end
