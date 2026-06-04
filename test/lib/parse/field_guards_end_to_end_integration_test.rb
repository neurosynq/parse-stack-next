require_relative "../../test_helper_integration"
require_relative "../../support/webhook_test_server"

# End-to-end integration test for the field_guards feature, exercising the
# full pipeline:
#
#   Parse Server (Docker) -> HTTP POST webhook -> in-process WEBrick ->
#   Parse::Webhooks Rack app -> guard application -> response ->
#   Parse Server persists -> MongoDB
#
# Requires Docker (PARSE_TEST_USE_DOCKER=true) and a Parse Server container
# whose `host.docker.internal` resolves back to the test host. The
# docker-compose adds `extra_hosts: ["host.docker.internal:host-gateway"]`
# so this works on Linux as well as Docker Desktop.
#
# Skipped automatically if the test server cannot be reached from inside
# the Parse Server container.

class GuardedE2EThing < Parse::Object
  parse_class "GuardedE2EThing"
  # These E2E tests exercise non-master client writes through the webhook
  # layer. The 4.1.0 default-private policy would block non-master writes
  # at the ACL gate before any webhook handler runs, hiding what field
  # guards actually do. Opt into public R/W so the webhook is the only
  # thing gating client writes.
  acl_policy :public
  property :title, :string
  property :owner, :string
  property :slug, :string

  guard :owner, :master_only
  guard :slug, :immutable
end

# Used for the after_save no-double-fire regression. A class-level counter
# tracks how many times the local ActiveModel after_save callback fired.
class GuardedAfterSaveCounter < Parse::Object
  parse_class "GuardedAfterSaveCounter"
  acl_policy :public
  property :title, :string
  property :status, :string
  guard :status, :immutable

  class << self
    attr_accessor :send_email_count
  end
  self.send_email_count = 0

  after_save :record_after_save
  def record_after_save
    self.class.send_email_count += 1
  end
end

# Used for end-to-end belongs_to pointer guard. The owner field is a
# Parse::User pointer that clients must never write directly.
class GuardedOwnerHolder < Parse::Object
  parse_class "GuardedOwnerHolder"
  acl_policy :public
  property :title, :string
  belongs_to :owner, as: :_user
  guard :owner, :master_only
end

# Used for end-to-end has_many :relation guard. tags is a Parse Relation
# to GuardedTag; non-master clients must not be able to add/remove via
# raw __op: AddRelation payloads.
class GuardedTag < Parse::Object
  parse_class "GuardedTag"
  acl_policy :public
  property :label, :string
end

class GuardedTaggedThing < Parse::Object
  parse_class "GuardedTaggedThing"
  acl_policy :public
  property :name, :string
  has_many :tags, as: :guarded_tag, through: :relation
  guard :tags, :master_only
end

# Used for halt/reject tests. A class whose webhook before_save block can
# be configured per-test to reject the save.
class GuardedRejectable < Parse::Object
  parse_class "GuardedRejectable"
  acl_policy :public
  property :title, :string
  property :owner, :string
  guard :owner, :master_only
end

# Frozen-after-create field, even against master writes.
class GuardedAlwaysImmutableThing < Parse::Object
  parse_class "GuardedAlwaysImmutableThing"
  acl_policy :public
  property :slug, :string
  property :note, :string
  guard :slug, :always_immutable
end

# ACL guard end-to-end class. Intentionally does NOT declare acl_policy
# since this class' purpose is to exercise the ACL field guard itself.
class GuardedAclThing < Parse::Object
  parse_class "GuardedAclThing"
  property :title, :string
  guard :acl, :master_only
end

module FieldGuardsEndToEndSetup
  # Prepended so `super` runs the `define_method :setup` installed by
  # ParseStackIntegrationTest (which handles Parse.setup and DB reset)
  # before our webhook-specific setup. A plain `def setup; super; ...; end`
  # on the test class would shadow the include's define_method'd setup,
  # so super would skip past it to Minitest::Test#setup.
  def setup
    super
    Parse::Webhooks.instance_variable_set(:@routes, nil)
    Parse::Webhooks.allow_unauthenticated = true
    # The test Rack server is reachable from the Parse Server container via
    # host.docker.internal, which does not resolve from the host running this
    # process. Bypass the registration-time SSRF guard so the URL passes.
    # Capture/restore via the ivar directly so teardown does not reinstate
    # the ENV-fallback default when the prior value happened to be nil.
    @prior_allow_private_webhook_urls = Parse::Webhooks.instance_variable_get(:@allow_private_webhook_urls)
    Parse::Webhooks.allow_private_webhook_urls = true

    # Re-register the auto-stub for every guarded test class. We wiped
    # @routes above, so each class's load-time guard declarations need to
    # re-run `ensure_field_guards_webhook!`. `guard` is idempotent against
    # field_guards itself (class_attribute), so this only affects routes.
    [GuardedE2EThing, GuardedAfterSaveCounter, GuardedOwnerHolder,
     GuardedTaggedThing, GuardedRejectable,
     GuardedAlwaysImmutableThing, GuardedAclThing].each do |klass|
      klass.field_guards.each { |field, mode| klass.guard(field, mode) }
    end

    # Reset the counter for tests that rely on it
    GuardedAfterSaveCounter.send_email_count = 0

    @server = Parse::Test::WebhookTestServer.new.start!

    unless docker_can_reach_host?
      @server.stop!
      skip "Parse Server container cannot reach the test host at " \
           "#{@server.url}; ensure docker-compose has " \
           "extra_hosts: [\"host.docker.internal:host-gateway\"] and that " \
           "no firewall blocks the bound port."
    end

    # Point Parse Server at our local Rack app for the GuardedE2EThing
    # class. register_triggers! iterates routes; since guard auto-registers
    # the before_save route, this registers exactly what we need.
    Parse::Webhooks.register_triggers!(@server.url)
  end

  def teardown
    begin
      Parse::Webhooks.remove_all_triggers! if @server
    rescue StandardError
      # Swallow teardown reachability failures; parent resets DB anyway.
    end
    @server&.stop!
    Parse::Webhooks.allow_unauthenticated = false
    Parse::Webhooks.instance_variable_set(:@allow_private_webhook_urls, @prior_allow_private_webhook_urls)
    super
  end
end

class FieldGuardsEndToEndIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  prepend FieldGuardsEndToEndSetup

  def test_master_only_field_dropped_on_client_create
    # Non-master client posts a create that includes a guarded field.
    body = {
      "title" => "ok",
      "slug" => "permitted-on-create",
      "owner" => "ATTACKER-tried-this",
    }
    object_id = non_master_create("GuardedE2EThing", body)

    fetched = master_fetch("GuardedE2EThing", object_id)
    assert_equal "ok", fetched["title"], "unguarded field persisted"
    assert_equal "permitted-on-create", fetched["slug"],
                 "immutable field is settable on create"
    refute fetched.key?("owner"),
           "master_only field MUST NOT survive non-master create. Got: #{fetched.inspect}"
  end

  def test_master_key_create_can_set_master_only_field
    object_id = master_create("GuardedE2EThing", {
      "title" => "by master",
      "owner" => "set-by-master",
    })
    fetched = master_fetch("GuardedE2EThing", object_id)
    assert_equal "set-by-master", fetched["owner"],
                 "master key bypasses master_only guard"
  end

  def test_immutable_field_blocked_on_client_update
    # Create as master so we have a known starting slug
    id = master_create("GuardedE2EThing", { "title" => "initial", "slug" => "first-slug" })

    # Non-master client tries to change the immutable slug
    non_master_update("GuardedE2EThing", id, { "slug" => "client-tried-to-change", "title" => "updated" })

    fetched = master_fetch("GuardedE2EThing", id)
    assert_equal "first-slug", fetched["slug"],
                 "immutable slug must remain unchanged on client update"
    assert_equal "updated", fetched["title"],
                 "unguarded title still updated successfully"
  end

  def test_master_can_update_immutable_field
    id = master_create("GuardedE2EThing", { "title" => "x", "slug" => "first" })
    master_update("GuardedE2EThing", id, { "slug" => "master-changed-this" })
    fetched = master_fetch("GuardedE2EThing", id)
    assert_equal "master-changed-this", fetched["slug"],
                 "master key bypasses immutable guard"
  end

  def test_before_save_idempotency_with_repeated_client_saves
    # Client SDKs typically re-send the entire record on every save, not
    # just changed fields. A guarded field will appear in every payload.
    # Each save must succeed silently -- no error, no state corruption,
    # consistent results across repeated saves.
    id = master_create("GuardedE2EThing",
                       "title" => "stable",
                       "slug" => "stable-slug",
                       "owner" => "system-owner")

    # Client repeatedly sends the full record (including the guarded
    # owner/slug values it never legitimately set). Title alternates so
    # we can verify each save actually persisted.
    titles = ["edit-1", "edit-2", "edit-3", "edit-3", "edit-3"]
    titles.each_with_index do |new_title, i|
      non_master_update("GuardedE2EThing", id, {
        "title" => new_title,
        # Client re-sends the guarded fields with stale/wrong values.
        # Idempotency means each request must succeed and not
        # corrupt the persisted owner/slug.
        "slug" => "client-tried-#{i}",
        "owner" => "client-tried-#{i}",
      })
    end

    final = master_fetch("GuardedE2EThing", id)
    assert_equal "edit-3", final["title"], "last unguarded write persisted"
    assert_equal "stable-slug", final["slug"],
                 "immutable slug remains stable across repeated saves"
    assert_equal "system-owner", final["owner"],
                 "master_only owner remains stable across repeated saves"
  end

  def test_before_save_idempotency_on_repeated_creates
    # Same record posted three times (different objects each time, since
    # this is a create). Each must yield an object with the guarded field
    # absent or master-defaulted, and behavior must be identical.
    ids = 3.times.map do |i|
      non_master_create("GuardedE2EThing", {
        "title" => "repeated-#{i}",
        "owner" => "ATTACKER-#{i}",
      })
    end

    fetched_owners = ids.map { |id| master_fetch("GuardedE2EThing", id).key?("owner") }
    refute fetched_owners.any?, "every repeated create must drop the master_only field; saw: #{fetched_owners.inspect}"
  end

  def test_ruby_initiated_save_runs_each_callback_exactly_once
    # When parse-stack itself initiates the save:
    #
    #   GuardedE2EThing.new.save
    #     -> Ruby before_save callback runs locally (once)
    #     -> REST POST with X-Parse-Request-Id: _RB_...
    #     -> Parse Server invokes the registered webhook
    #     -> Our webhook block runs (once)
    #     -> Parse Server persists, responds
    #     -> Parse Server invokes the registered afterSave webhook
    #     -> Our after_save block runs (once)
    #     -> Ruby after_save callback runs locally (once)
    #
    # The framework must NOT cause any of these to fire twice. ActiveModel
    # callbacks should run on the Ruby side only; the webhook handler block
    # should run on the server side only.

    # Counters are class-level so the webhook block (which runs in a separate
    # call_route invocation) can update them and the test can read them.
    cleanup_counter_class = GuardedE2EThing
    cleanup_counter_class.instance_variable_set(:@ruby_before_save_count, 0)
    cleanup_counter_class.instance_variable_set(:@ruby_after_save_count, 0)
    cleanup_counter_class.instance_variable_set(:@webhook_before_save_count, 0)
    cleanup_counter_class.instance_variable_set(:@webhook_after_save_count, 0)

    # Register Ruby-side callbacks dynamically -- we don't want them on the
    # class permanently because they'd affect other tests.
    rb_before = -> { GuardedE2EThing.instance_variable_set(:@ruby_before_save_count,
                                                            GuardedE2EThing.instance_variable_get(:@ruby_before_save_count) + 1); true }
    rb_after  = -> { GuardedE2EThing.instance_variable_set(:@ruby_after_save_count,
                                                            GuardedE2EThing.instance_variable_get(:@ruby_after_save_count) + 1); true }
    GuardedE2EThing.set_callback(:save, :before, rb_before)
    GuardedE2EThing.set_callback(:save, :after, rb_after)

    # Register the webhook blocks (these replace the auto-stub from `guard`).
    Parse::Webhooks.route(:before_save, "GuardedE2EThing") do
      GuardedE2EThing.instance_variable_set(:@webhook_before_save_count,
                                             GuardedE2EThing.instance_variable_get(:@webhook_before_save_count) + 1)
      parse_object
    end
    Parse::Webhooks.route(:after_save, "GuardedE2EThing") do
      GuardedE2EThing.instance_variable_set(:@webhook_after_save_count,
                                             GuardedE2EThing.instance_variable_get(:@webhook_after_save_count) + 1)
      true
    end

    # Re-register the trigger URLs with Parse Server so it routes both
    # before_save and after_save to our local server. (Setup already called
    # register_triggers! once, but only before_save was registered then since
    # there was no after_save route. Call again now that after_save exists.)
    Parse::Webhooks.register_triggers!(@server.url)

    obj = GuardedE2EThing.new(title: "ruby-initiated", slug: "ruby-slug")
    obj.save

    # Give Parse Server a moment to dispatch the asynchronous after_save webhook.
    deadline = Time.now + 5
    while Time.now < deadline && GuardedE2EThing.instance_variable_get(:@webhook_after_save_count) == 0
      sleep 0.1
    end

    assert_equal 1, GuardedE2EThing.instance_variable_get(:@ruby_before_save_count),
                 "Ruby before_save callback must fire exactly once locally"
    assert_equal 1, GuardedE2EThing.instance_variable_get(:@ruby_after_save_count),
                 "Ruby after_save callback must fire exactly once locally"
    assert_equal 1, GuardedE2EThing.instance_variable_get(:@webhook_before_save_count),
                 "webhook before_save block must fire exactly once server-side"
    assert_equal 1, GuardedE2EThing.instance_variable_get(:@webhook_after_save_count),
                 "webhook after_save block must fire exactly once server-side"
  ensure
    # Remove the test-scoped Ruby callbacks so they don't leak to other tests.
    if defined?(rb_before) && rb_before
      GuardedE2EThing.skip_callback(:save, :before, rb_before) rescue nil
      GuardedE2EThing.skip_callback(:save, :after, rb_after) rescue nil
    end
  end

  def test_after_save_fires_exactly_once_on_ruby_initiated_update
    # Regression for the run_after_save_callbacks double-fire bug in
    # call_route. The previous condition `unless (is_new && ruby_initiated)`
    # let ruby-initiated UPDATES re-fire the after_save callback inside the
    # webhook, which would then fire AGAIN locally when save() returned.
    # Result: a model with `after_save :send_email` sent two emails per
    # update. After the fix, this assertion holds: exactly one fire per save.

    # Register an after_save webhook so Parse Server actually dispatches the
    # afterSave trigger and we can wait for it. We increment a counter
    # inside the block to know when the webhook has been called -- this
    # gives us a deterministic wait condition rather than a fixed sleep.
    webhook_fires = { count: 0 }
    Parse::Webhooks.route(:after_save, "GuardedAfterSaveCounter") do
      webhook_fires[:count] += 1
      true
    end
    Parse::Webhooks.register_triggers!(@server.url)

    GuardedAfterSaveCounter.send_email_count = 0

    # Create first
    obj = GuardedAfterSaveCounter.new(title: "invite", status: "pending")
    obj.save
    wait_until("webhook after_save fires for create") { webhook_fires[:count] >= 1 }
    count_after_create = GuardedAfterSaveCounter.send_email_count

    # Now update -- this is the case the bug regressed
    obj.title = "invite-updated"
    obj.save
    wait_until("webhook after_save fires for update") { webhook_fires[:count] >= 2 }

    delta = GuardedAfterSaveCounter.send_email_count - count_after_create
    assert_equal 1, delta,
                 "after_save must fire exactly ONCE on a ruby-initiated update " \
                 "(local + webhook double-fire would send two emails per save)"
  end

  def test_belongs_to_master_only_blocks_client_pointer_write
    # A non-master client tries to set the guarded `owner` belongs_to
    # pointer on a brand-new record. Parse Server must persist without
    # the owner field; the client cannot inject a relationship that the
    # server is supposed to assign.

    # Need an existing user we'll try (and fail) to point to.
    user_id = master_create("_User", {
      "username" => "target-user-#{Time.now.to_i}",
      "password" => "secret",
    })

    object_id = non_master_create("GuardedOwnerHolder", {
      "title" => "thing",
      "owner" => { "__type" => "Pointer", "className" => "_User", "objectId" => user_id },
    })

    fetched = master_fetch("GuardedOwnerHolder", object_id)
    refute fetched.key?("owner"),
           "non-master client must not be able to write a guarded belongs_to pointer; " \
           "MongoDB shows: #{fetched.inspect}"
    assert_equal "thing", fetched["title"], "unguarded title still saved"
  end

  def test_belongs_to_master_only_allows_master_pointer_write
    user_id = master_create("_User", {
      "username" => "target-user-#{Time.now.to_i}-master",
      "password" => "secret",
    })

    object_id = master_create("GuardedOwnerHolder", {
      "title" => "by-master",
      "owner" => { "__type" => "Pointer", "className" => "_User", "objectId" => user_id },
    })
    fetched = master_fetch("GuardedOwnerHolder", object_id)
    assert_equal user_id, fetched.dig("owner", "objectId"),
                 "master key may assign the guarded belongs_to"
  end

  def test_has_many_relation_master_only_blocks_client_add_relation_op
    # A non-master client posts a create with a raw `__op: AddRelation`
    # for a guarded `has_many :through => :relation` field. Parse Server
    # must persist no entries in the relation table.

    tag_id = master_create("GuardedTag", { "label" => "important" })

    thing_id = non_master_create("GuardedTaggedThing", {
      "name" => "tagged-thing",
      "tags" => {
        "__op" => "AddRelation",
        "objects" => [{ "__type" => "Pointer", "className" => "GuardedTag", "objectId" => tag_id }],
      },
    })

    # Verify the relation is empty by querying related GuardedTag objects.
    where = {
      "$relatedTo" => {
        "object" => { "__type" => "Pointer", "className" => "GuardedTaggedThing", "objectId" => thing_id },
        "key" => "tags",
      },
    }
    response = Parse.client.request(
      :get,
      "classes/GuardedTag",
      query: { "where" => where.to_json },
    )
    # response.result is the unwrapped results array for query responses.
    related = response.result
    related = [] if related.nil?
    related = [related] unless related.is_a?(Array)
    assert_empty related,
                 "non-master AddRelation on guarded has_many :relation must not persist; " \
                 "got: #{related.inspect}"
  end

  def test_webhook_block_error_bang_halts_save
    # If the webhook before_save block raises a Parse::Webhooks::ResponseError
    # (typically via payload.error!("...")), Parse Server must reject the
    # save and persist nothing.
    Parse::Webhooks.route(:before_save, "GuardedRejectable") do
      error!("policy violation: rejected")
    end
    Parse::Webhooks.register_triggers!(@server.url)

    response = Parse.client.request(
      :post,
      "classes/GuardedRejectable",
      body: { "title" => "should-not-save" }.to_json,
      headers: { "X-Parse-Master-Key" => "" },
      opts: { use_master_key: false },
    )
    assert response.error?, "webhook error! must surface as Parse Server error response"

    # And nothing was persisted. Query master to be sure.
    persisted = list_objects("GuardedRejectable")
    refute persisted.any? { |r| r["title"] == "should-not-save" },
           "rejected save must not have persisted any object"
  end

  def test_webhook_block_returning_false_halts_save
    # Returning `false` from a before_save block is the documented way to
    # halt a save in parse-stack. The framework raises ResponseError
    # internally; Parse Server returns the failure to the client.
    Parse::Webhooks.route(:before_save, "GuardedRejectable") { false }
    Parse::Webhooks.register_triggers!(@server.url)

    response = Parse.client.request(
      :post,
      "classes/GuardedRejectable",
      body: { "title" => "halted-by-false" }.to_json,
      headers: { "X-Parse-Master-Key" => "" },
      opts: { use_master_key: false },
    )
    assert response.error?, "returning false from before_save must surface as Parse Server error"

    persisted = list_objects("GuardedRejectable")
    refute persisted.any? { |r| r["title"] == "halted-by-false" },
           "halted save must not persist"
  end

  def test_always_immutable_blocks_master_update
    # The point of :always_immutable: even master-key updates are reverted
    # after the object is created. Useful for fields that must NEVER change
    # (canonical slugs, terminal state markers, etc.).
    id = master_create("GuardedAlwaysImmutableThing", {
      "slug" => "permanent",
      "note" => "v1",
    })

    # Master tries to change the always-immutable slug. The note (unguarded)
    # should still go through.
    master_update("GuardedAlwaysImmutableThing", id, {
      "slug" => "master-tried-to-rename",
      "note" => "v2",
    })

    fetched = master_fetch("GuardedAlwaysImmutableThing", id)
    assert_equal "permanent", fetched["slug"],
                 ":always_immutable must reject even master-key updates"
    assert_equal "v2", fetched["note"], "unguarded field passed through"
  end

  def test_always_immutable_allows_master_create
    id = master_create("GuardedAlwaysImmutableThing", {
      "slug" => "set-on-create",
      "note" => "init",
    })
    fetched = master_fetch("GuardedAlwaysImmutableThing", id)
    assert_equal "set-on-create", fetched["slug"]
  end

  def test_acl_master_only_blocks_client_acl_writes
    # Start with a publicly-writable ACL so a non-master client can perform
    # the update at all (otherwise the request is blocked by Parse Server's
    # ACL enforcement before our webhook runs, and we wouldn't be testing
    # the guard). The guard's job is to revert the client's *change to the
    # ACL itself* while still letting title changes through.
    starting_acl = { "*" => { "read" => true, "write" => true } }
    id = master_create("GuardedAclThing", {
      "title" => "starting-title",
      "ACL" => starting_acl,
    })

    # Client tries to narrow ACL to lock out the master/admin -- a credible
    # attack scenario for a malicious client who wants to claim ownership.
    locked_acl = { "u_attacker" => { "read" => true, "write" => true } }
    non_master_update("GuardedAclThing", id, {
      "title" => "updated-title",
      "ACL" => locked_acl,
    })

    fetched = master_fetch("GuardedAclThing", id)
    assert_equal starting_acl, fetched["ACL"],
                 "client ACL change must be reverted; persisted ACL unchanged"
    assert_equal "updated-title", fetched["title"],
                 "unguarded title field still saved"
  end

  def test_acl_master_only_allows_master_acl_change
    restrictive_acl = { "u_owner" => { "read" => true, "write" => true } }
    new_acl = { "u_owner" => { "read" => true, "write" => true },
                "u_admin" => { "read" => true, "write" => true } }
    id = master_create("GuardedAclThing", {
      "title" => "x",
      "ACL" => restrictive_acl,
    })
    master_update("GuardedAclThing", id, { "ACL" => new_acl })
    fetched = master_fetch("GuardedAclThing", id)
    assert_equal new_acl, fetched["ACL"], "master may change ACL"
  end

  def test_spoofed_ruby_initiated_header_does_not_bypass
    # Security: a client sending X-Parse-Request-Id starting with _RB_ must
    # NOT bypass guards. Parse Server forwards client request headers into
    # the webhook body, so this header is client-controlled.
    object_id = non_master_create(
      "GuardedE2EThing",
      { "title" => "spoofed", "owner" => "attacker-via-rb-prefix" },
      extra_headers: { "X-Parse-Request-Id" => "_RB_attacker_spoof" },
    )
    fetched = master_fetch("GuardedE2EThing", object_id)
    refute fetched.key?("owner"),
           "spoofed _RB_ request id must not bypass master_only enforcement"
  end

  private

  def list_objects(class_name)
    response = Parse.client.request(:get, "classes/#{class_name}")
    result = response.result
    return [] if result.nil?
    return result if result.is_a?(Array)
    [result]
  end

  def wait_until(description, timeout: 5)
    deadline = Time.now + timeout
    loop do
      return if yield
      flunk "timed out (#{timeout}s) waiting for: #{description}" if Time.now >= deadline
      sleep 0.05
    end
  end

  def docker_can_reach_host?
    # Use a busybox-free probe: just see if the parse container can resolve
    # and connect to our port. We don't strictly need a successful HTTP
    # response -- a TCP connect is enough to confirm reachability.
    result = `docker exec #{ENV["PSNEXT_PREFIX"] || "psnext-it"}-server sh -c 'getent hosts host.docker.internal' 2>&1`
    !result.empty? && $?.success?
  end

  def non_master_create(class_name, body, extra_headers: {})
    response = Parse.client.request(
      :post,
      "classes/#{class_name}",
      body: body.to_json,
      headers: { "X-Parse-Master-Key" => "" }.merge(extra_headers),
      opts: { use_master_key: false },
    )
    response.result["objectId"]
  end

  def master_create(class_name, body)
    response = Parse.client.request(:post, "classes/#{class_name}", body: body.to_json)
    response.result["objectId"]
  end

  def non_master_update(class_name, object_id, body, extra_headers: {})
    Parse.client.request(
      :put,
      "classes/#{class_name}/#{object_id}",
      body: body.to_json,
      headers: { "X-Parse-Master-Key" => "" }.merge(extra_headers),
      opts: { use_master_key: false },
    )
  end

  def master_update(class_name, object_id, body)
    Parse.client.request(:put, "classes/#{class_name}/#{object_id}", body: body.to_json)
  end

  def master_fetch(class_name, object_id)
    Parse.client.request(:get, "classes/#{class_name}/#{object_id}").result
  end
end
