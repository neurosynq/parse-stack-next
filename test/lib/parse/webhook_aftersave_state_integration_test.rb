require_relative "../../test_helper_integration"
require_relative "../../support/webhook_test_server"

# End-to-end integration test for the state of the Parse::Object handed to an
# afterSave webhook block, exercising the full pipeline:
#
#   Parse Server (Docker) -> HTTP POST afterSave webhook -> in-process WEBrick ->
#   Parse::Webhooks Rack app -> webhook block -> capture object state
#
# This focuses on the two questions webhook authors actually rely on inside an
# afterSave handler for objects created by a non-Ruby client (REST / JS cloud
# code / Auth0):
#
#   1. New-object detection -- "is this the first save of this object?" The
#      idioms in the wild are `payload.original.nil?`, `new?`, and `existed?`.
#   2. Change detection -- "which fields changed on this update?" via
#      dirty tracking (`changed`, `*_changed?`, `changes`).
#
# Requires Docker (PARSE_TEST_USE_DOCKER=true) and a Parse Server container
# whose `host.docker.internal` resolves back to the test host. Skipped
# automatically if the test server cannot be reached from the container.

# Neutral domain class (see CLAUDE.md domain-term hygiene). acl_policy :public
# so a non-master client create/update is not blocked at the ACL gate before
# the webhook runs -- the non-master path is the whole point (mimics Auth0/JS).
class WebhookStatePost < Parse::Object
  parse_class "WebhookStatePost"
  acl_policy :public
  property :title, :string
  property :status, :string
  property :body, :string

  # Records, per phase, whether the model-level after_* callbacks fired and
  # what the dirty state looked like at callback time. Lets us prove point 2:
  # a side effect gated on `*_changed?` silently no-ops on an afterSave object.
  class << self
    attr_accessor :model_callbacks
  end
  self.model_callbacks = []

  before_save   :__record_before_save
  before_create :__record_before_create
  after_create  :__record_after_create
  after_save    :__record_after_save

  def __record(hook)
    self.class.model_callbacks << {
      hook: hook,
      new?: new?,
      existed?: existed?,
      changed: changed.dup,
      title_changed?: title_changed?,
    }
    true
  end

  def __record_before_save = __record(:before_save)
  def __record_before_create = __record(:before_create)
  def __record_after_create = __record(:after_create)
  def __record_after_save = __record(:after_save)
end

module WebhookAfterSaveStateSetup
  def setup
    super
    Parse::Webhooks.instance_variable_set(:@routes, nil)
    Parse::Webhooks.allow_unauthenticated = true
    @prior_allow_private_webhook_urls = Parse::Webhooks.instance_variable_get(:@allow_private_webhook_urls)
    Parse::Webhooks.allow_private_webhook_urls = true

    WebhookStatePost.model_callbacks = []

    @server = Parse::Test::WebhookTestServer.new.start!

    unless docker_can_reach_host?
      @server.stop!
      skip "Parse Server container cannot reach the test host at " \
           "#{@server.url}; ensure docker-compose has " \
           "extra_hosts: [\"host.docker.internal:host-gateway\"]."
    end
  end

  def teardown
    begin
      Parse::Webhooks.remove_all_triggers! if @server
    rescue StandardError
      # parent resets DB anyway
    end
    @server&.stop!
    Parse::Webhooks.allow_unauthenticated = false
    Parse::Webhooks.instance_variable_set(:@allow_private_webhook_urls, @prior_allow_private_webhook_urls)
    super
  end
end

class WebhookAfterSaveStateIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  prepend WebhookAfterSaveStateSetup

  # ====================================================================
  # HARD-ASSERTION regression tests (modeled on
  # field_guards_end_to_end_integration_test.rb). These exercise the full
  # Docker pipeline (real Parse Server -> HTTP webhook -> Rack app) and assert
  # the full-object contract end to end: the webhook path preserves
  # server-authoritative createdAt/updatedAt/ACL (only credentials are scrubbed
  # via Parse::Webhooks::Payload#scrub_credentials), so existed?/new? are
  # reliable and afterSave updates carry dirty tracking. The unit suite in
  # webhook_aftersave_payload_fidelity_test.rb pins the same contract off Docker.
  # ====================================================================

  # Captures the built-object state seen inside the afterSave handler so the
  # test body can assert on it after the webhook fires.
  def capture_after_save(class_name)
    captured = {}
    Parse::Webhooks.route(:after_save, class_name) do
      obj = parse_object
      orig = original_parse_object
      captured[:fired] = true
      captured[:payload_original_nil] = original.nil?
      raw_obj = @raw.is_a?(Hash) ? @raw[:object] : nil
      captured[:raw_object_keys] = raw_obj.is_a?(Hash) ? raw_obj.keys.sort : nil
      captured[:raw_createdAt] = raw_obj.is_a?(Hash) ? raw_obj["createdAt"] : nil
      captured[:raw_updatedAt] = raw_obj.is_a?(Hash) ? raw_obj["updatedAt"] : nil
      captured[:raw_has_acl] = raw_obj.is_a?(Hash) ? raw_obj.key?("ACL") : false
      if obj
        captured[:id] = obj.id
        captured[:new?] = obj.new?
        captured[:existed?] = obj.existed?
        captured[:created_at] = obj.created_at
        captured[:updated_at] = obj.updated_at
        captured[:acl_present] = !obj.acl.nil?
        captured[:title] = obj.title
        captured[:title_changed?] = obj.title_changed?
        captured[:changed] = obj.changed.dup
        captured[:changes] = obj.changes
      end
      captured[:orig_title] = orig&.title
      true
    end
    Parse::Webhooks.register_triggers!(@server.url)
    captured
  end

  def test_b_new_object_full_state_on_nonmaster_create
    captured = capture_after_save("WebhookStatePost")

    id = non_master_create("WebhookStatePost", { "title" => "hello", "status" => "draft" })
    wait_until("afterSave fires for non-master create") { captured[:fired] }

    assert id, "create returned an id"
    assert_equal id, captured[:id], "handler saw the persisted objectId"
    assert captured[:payload_original_nil], "a create has no original"

    # Parse Server sends createdAt == updatedAt on a fresh create.
    assert_equal captured[:raw_createdAt], captured[:raw_updatedAt],
                 "createdAt == updatedAt on a fresh create (raw payload)"
    refute_nil captured[:raw_createdAt], "Parse Server sends createdAt for a create"

    # ---- SPEC (FAILS ON HEAD: scrub strips timestamps) ----
    refute_nil captured[:created_at],
               "[SPEC] built object must expose server createdAt in afterSave"
    refute_nil captured[:updated_at],
               "[SPEC] built object must expose server updatedAt in afterSave"
    refute captured[:existed?],
           "a brand-new object must report existed? == false"

    # afterSave-create dirty tracking: the created fields are reported changed,
    # so a handler can build a sync payload from #changed / *_changed? on a
    # create the same way it does on an update.
    assert captured[:title_changed?],
           "afterSave create reports the created field as changed"
    assert_includes captured[:changed], "title",
                    "the created field appears in #changed on an afterSave create"
  end

  def test_b_new_object_full_state_on_ruby_model_save
    # Ruby-initiated create via the model API. The afterSave webhook still
    # fires server-side; the handler must see the same full state.
    captured = capture_after_save("WebhookStatePost")

    obj = WebhookStatePost.new(title: "ruby-create", status: "draft")
    obj.save
    wait_until("afterSave fires for ruby model save") { captured[:fired] }

    assert captured[:fired], "afterSave must fire for a Ruby model save"
    refute_nil captured[:id], "handler saw an objectId for the Ruby-created object"
    assert_equal captured[:raw_createdAt], captured[:raw_updatedAt],
                 "createdAt == updatedAt on a fresh Ruby-initiated create"

    # ---- SPEC (FAILS ON HEAD) ----
    refute_nil captured[:created_at],
               "[SPEC] built object must expose createdAt for a Ruby model save"
    refute captured[:existed?], "Ruby-created object must report existed? == false"

    # afterSave-create dirty tracking holds for a Ruby-initiated save too.
    assert captured[:title_changed?],
           "afterSave create reports the created field as changed (Ruby save)"
    assert_includes captured[:changed], "title",
                    "the created field appears in #changed (Ruby save)"
  end

  def test_b_changed_object_full_state_and_change_detection_on_update
    # Seed as master WITH an explicit ACL so Parse Server includes ACL,
    # createdAt and updatedAt in the afterSave payload (confirmed behavior:
    # a record that carries an ACL emits ACL/createdAt/updatedAt on update).
    id = master_create("WebhookStatePost", {
      "title" => "original-title", "status" => "draft", "body" => "v1",
      "ACL" => { "u_owner" => { "read" => true, "write" => true },
                 "*" => { "read" => true, "write" => true } },
    })

    captured = capture_after_save("WebhookStatePost")

    non_master_update("WebhookStatePost", id, { "title" => "changed-title" })
    wait_until("afterSave fires for non-master update") { captured[:fired] }

    refute captured[:payload_original_nil], "an update carries original"
    assert_equal "original-title", captured[:orig_title],
                 "original_parse_object retains the previous title"
    assert_equal "changed-title", captured[:title],
                 "built object reflects the new title"

    # Raw payload carries server-authoritative fields on an ACL-bearing record.
    refute_nil captured[:raw_createdAt], "raw createdAt present on update"
    refute_nil captured[:raw_updatedAt], "raw updatedAt present on update"
    refute_equal captured[:raw_createdAt], captured[:raw_updatedAt],
                 "createdAt < updatedAt on an update (raw payload)"
    assert captured[:raw_has_acl], "raw payload includes ACL for an ACL-bearing record"

    # ACL survives scrubbing today and must keep surviving.
    assert captured[:acl_present], "built object must expose the ACL in afterSave"

    # ---- SPEC (FAILS ON HEAD: timestamps stripped => existed? false) ----
    refute_nil captured[:created_at], "[SPEC] built object must expose createdAt on update"
    refute_nil captured[:updated_at], "[SPEC] built object must expose updatedAt on update"
    assert captured[:existed?],
           "[SPEC] existed? must be true for an updated (already-persisted) object"

    # ---- Change detection: TODAY variant (holds on HEAD) ----
    refute_equal captured[:orig_title], captured[:title],
                 "field change is detectable by comparing original vs object"

    # ---- Change detection: FIX variant (SPEC, FAILS ON HEAD) ----
    assert captured[:title_changed?],
           "[SPEC] title_changed? must be true on an afterSave update"
    assert_includes captured[:changed], "title",
                    "[SPEC] changed must include the mutated field"
  end

  def test_b_full_lifecycle_order_end_to_end_on_nonmaster_create
    # End-to-end proof that a client-initiated create runs the model lifecycle
    # callbacks in ActiveModel order through a real Parse Server: the beforeSave
    # webhook runs before_save then before_create (Parse Server has no separate
    # beforeCreate trigger), and the afterSave webhook runs after_create then
    # after_save. This is the gap the fix closes -- before_create previously
    # never ran for REST/JS/Auth0-created objects, and after_save double-fired.
    WebhookStatePost.model_callbacks = []
    Parse::Webhooks.route(:before_save, "WebhookStatePost") { parse_object }
    Parse::Webhooks.route(:after_save, "WebhookStatePost") { true }
    Parse::Webhooks.register_triggers!(@server.url)

    non_master_create("WebhookStatePost", { "title" => "lifecycle", "status" => "draft" })
    wait_until("after_save model callback fires") do
      WebhookStatePost.model_callbacks.any? { |c| c[:hook] == :after_save }
    end

    order = WebhookStatePost.model_callbacks.map { |c| c[:hook] }
    assert_equal [:before_save, :before_create, :after_create, :after_save], order,
                 "client create must run the lifecycle in ActiveModel order exactly once each; got #{order.inspect}"

    # after_* callbacks see the persisted object (timestamps present).
    after_create = WebhookStatePost.model_callbacks.find { |c| c[:hook] == :after_create }
    refute after_create[:existed?], "after_create on a fresh create reports existed? == false"
  end

  private

  def wait_until(description, timeout: 8)
    deadline = Time.now + timeout
    loop do
      return if yield
      flunk "timed out (#{timeout}s) waiting for: #{description}" if Time.now >= deadline
      sleep 0.05
    end
  end

  def docker_can_reach_host?
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
end
