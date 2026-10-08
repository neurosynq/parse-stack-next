require_relative "../../test_helper_integration"
require_relative "../../support/webhook_global_state"
require_relative "../../support/webhook_test_server"

# End-to-end checks for the beforeSave reply a Ruby webhook sends back when the
# handler changes the object (so the reply replaces the client's write):
#
#   Parse Server (Docker) -> HTTP POST beforeSave webhook -> in-process WEBrick
#   -> Parse::Webhooks Rack app -> handler -> reply -> Parse Server write
#
# - A client create that sends no ACL gets the ACL the class policy resolves.
#   Under the shipped `:owner_else_private` policy a signed-in client owns the
#   record and an anonymous one gets the master-only fallback. It never gets
#   Parse Server's own no-ACL default, which is public read and write.
# - An ACL the client sent is kept.
# - Concurrent top-level Increment operators all apply.
# - Concurrent dotted sub-key writes to different sub-keys all survive, and a
#   sub-key the client removed is deleted. The reply splits one level deep,
#   and a nested change saves cleanly when the class has an afterSave hook.
#
# Requires Docker (PARSE_TEST_USE_DOCKER=true) and a Parse Server container
# whose `host.docker.internal` resolves back to the test host.

# No acl_policy: the shipped default (`:owner_else_private`) is the case under
# test.
class WebhookReplyCounter < Parse::Object
  parse_class "WebhookReplyCounter"
  property :title, :string
  property :count, :integer
  property :meta, :object
end

class WebhookBeforeSaveReplyIntegrationTest < Minitest::Test
  include WebhookGlobalState
  include ParseStackIntegrationTest

  # Holds every concurrent handler call until all of them have arrived, so the
  # requests are inside the handler at the same time, each holding the same
  # stored `original`, before any of them replies.
  class Barrier
    def initialize(parties)
      @parties = parties
      @arrived = 0
      @lock = Mutex.new
      @all_in = ConditionVariable.new
    end

    def wait(timeout = 10)
      @lock.synchronize do
        @arrived += 1
        if @arrived >= @parties
          @all_in.broadcast
        else
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          while @arrived < @parties
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            break if remaining <= 0
            @all_in.wait(@lock, remaining)
          end
        end
      end
    end

    def met?
      @lock.synchronize { @arrived >= @parties }
    end
  end

  class << self
    attr_accessor :barrier
  end

  def setup
    super
    Parse::Webhooks.instance_variable_set(:@routes, nil)
    # Authenticate with the key the test Parse Server sends.
    @prior_webhook_key = Parse::Webhooks.instance_variable_get(:@key)
    Parse::Webhooks.key = Parse::Test::WebhookTestServer::KEY
    @prior_allow_private_webhook_urls = Parse::Webhooks.instance_variable_get(:@allow_private_webhook_urls)
    Parse::Webhooks.allow_private_webhook_urls = true
    @server = Parse::Test::WebhookTestServer.new.start!
    unless docker_can_reach_host?
      @server.stop!
      @server = nil
      skip "Parse Server container cannot reach the test host"
    end
    # The handler always changes `title` to a new value, so every reply
    # replaces the write. During a concurrency test the barrier holds each
    # call until all of them are in the handler.
    Parse::Webhooks.route(:before_save, "WebhookReplyCounter") do
      o = parse_object
      WebhookBeforeSaveReplyIntegrationTest.barrier&.wait
      o.title = "handled-#{SecureRandom.hex(4)}"
      o
    end
    Parse::Webhooks.register_triggers!(@server.url)
  end

  def teardown
    begin
      Parse::Webhooks.remove_all_triggers! if @server
    rescue StandardError
      # the parent resets the database anyway
    end
    @server&.stop!
    self.class.barrier = nil
    Parse::Webhooks.instance_variable_set(:@key, @prior_webhook_key)
    Parse::Webhooks.instance_variable_set(:@allow_private_webhook_urls, @prior_allow_private_webhook_urls)
    super
  end

  def test_signed_in_client_create_is_owned_by_the_requesting_user
    user_id, token = sign_up
    id = rest(:post, "classes/WebhookReplyCounter", { "title" => "new", "count" => 0 },
              master: false, session_token: token).result["objectId"]
    refute_nil id
    stored = fetch(id)
    assert_match(/\Ahandled-/, stored["title"])
    assert_equal({ user_id => { "read" => true, "write" => true } }, stored["ACL"])
    assert rest(:get, "classes/WebhookReplyCounter/#{id}", nil, master: false, session_token: token).success?,
           "the owner reads the record without the master key"
    refute rest(:get, "classes/WebhookReplyCounter/#{id}", nil, master: false).success?,
           "an anonymous client cannot read it"
  end

  def test_anonymous_client_create_gets_the_policy_fallback
    id = rest(:post, "classes/WebhookReplyCounter", { "title" => "new" }, master: false).result["objectId"]
    refute_nil id
    assert_equal({}, fetch(id)["ACL"], "never Parse Server's no-ACL default, which is public read and write")
    resp = rest(:put, "classes/WebhookReplyCounter/#{id}", { "title" => "anon" }, master: false)
    refute resp.success?, "an anonymous client cannot write the record"
  end

  def test_handler_private_acl_with_true_return_is_stored
    Parse::Webhooks.instance_variable_set(:@routes, nil)
    Parse::Webhooks.route(:before_save, "WebhookReplyCounter") do
      parse_object.acl = Parse::ACL.new
      true
    end
    id = rest(:post, "classes/WebhookReplyCounter", { "title" => "new" }, master: false).result["objectId"]
    refute_nil id
    stored = fetch(id)
    assert_equal "new", stored["title"], "a true return keeps the client's write"
    assert_equal({}, stored["ACL"], "the handler's private ACL is stored, not Parse Server's public default")
  end

  def test_client_acl_is_kept
    acl = { "*" => { "read" => true } }
    id = rest(:post, "classes/WebhookReplyCounter", { "title" => "new", "ACL" => acl }, master: false).result["objectId"]
    assert_equal acl, fetch(id)["ACL"]
  end

  def test_concurrent_increments_all_apply
    id = seed("count" => 0)
    concurrently(4, barrier: true) do
      rest(:put, "classes/WebhookReplyCounter/#{id}", { "count" => { "__op" => "Increment", "amount" => 1 } })
    end
    assert_equal 4, fetch(id)["count"]
  end

  def test_concurrent_dotted_writes_to_different_sub_keys_survive
    id = seed("meta" => { "a" => 1, "b" => 1, "c" => 1 })
    keys = %w[a b]
    concurrently(2, barrier: true) do |i|
      rest(:put, "classes/WebhookReplyCounter/#{id}", { "meta.#{keys[i]}" => { "__op" => "Increment", "amount" => 1 } })
    end
    assert_equal({ "a" => 2, "b" => 2, "c" => 1 }, fetch(id)["meta"])
  end

  # The reply is split one level deep, so concurrent changes inside two
  # different sub-documents both survive (each is written at its own
  # `meta.<sub>` path).
  def test_concurrent_writes_to_different_sub_documents_survive
    id = seed("meta" => { "count" => { "value" => 1 }, "other" => { "n" => 1 } })
    paths = %w[meta.count.value meta.other.n]
    concurrently(2, barrier: true) do |i|
      rest(:put, "classes/WebhookReplyCounter/#{id}", { paths[i] => { "__op" => "Increment", "amount" => 1 } })
    end
    assert_equal({ "count" => { "value" => 2 }, "other" => { "n" => 2 } }, fetch(id)["meta"])
  end

  # Parse Server rebuilds the afterSave object from a non-operator dotted key
  # only one level deep. A reply with a deeper path made the save response
  # fail after the write committed when the class had an afterSave hook.
  def test_nested_change_with_an_after_save_hook_succeeds_with_the_right_shape
    seen = Queue.new
    Parse::Webhooks.route(:after_save, "WebhookReplyCounter") do
      seen << parse_object.meta
      true
    end
    Parse::Webhooks.register_triggers!(@server.url)
    id = seed("meta" => { "count" => { "value" => 1, "other" => 1 }, "x" => 1 })
    resp = rest(:put, "classes/WebhookReplyCounter/#{id}", { "meta" => { "count" => { "value" => 5, "other" => 1 }, "x" => 1 } })
    assert resp.success?, "save failed: #{resp.result.inspect}"
    expected = { "count" => { "value" => 5, "other" => 1 }, "x" => 1 }
    assert_equal expected, fetch(id)["meta"]
    after = nil
    # The seed's own afterSave arrives first; keep the last one seen.
    deadline = Time.now + 10
    while Time.now < deadline
      begin
        after = seen.pop(true)
        break if after.is_a?(Hash) && after.dig("count", "value") == 5
      rescue ThreadError
        sleep 0.05
      end
    end
    assert_equal expected, after, "afterSave saw the stored shape"
  end

  def test_removed_sub_key_is_deleted
    id = seed("meta" => { "a" => 1, "b" => 1 })
    rest(:put, "classes/WebhookReplyCounter/#{id}", { "meta" => { "a" => 3 } })
    assert_equal({ "a" => 3 }, fetch(id)["meta"])
  end

  private

  def seed(fields)
    id = rest(:post, "classes/WebhookReplyCounter", { "title" => "seed", "ACL" => { "*" => { "read" => true, "write" => true } } }.merge(fields)).result["objectId"]
    refute_nil id
    id
  end

  def concurrently(n, barrier: false, &block)
    self.class.barrier = Barrier.new(n) if barrier
    responses = Array.new(n) { |i| Thread.new { block.call(i) } }.map(&:value)
    responses.each { |r| assert r.success?, "write failed: #{r.result.inspect}" }
    assert self.class.barrier.met?, "the writes never overlapped inside the handler" if barrier
  ensure
    self.class.barrier = nil
  end

  def sign_up
    name = "reply-#{SecureRandom.hex(6)}"
    resp = rest(:post, "users", { "username" => name, "password" => "pw-#{SecureRandom.hex(6)}" }, master: false)
    assert resp.success?, "signup failed: #{resp.result.inspect}"
    [resp.result["objectId"], resp.result["sessionToken"]]
  end

  def fetch(id)
    rest(:get, "classes/WebhookReplyCounter/#{id}", nil).result
  end

  def rest(method, path, body, master: true, session_token: nil)
    opts = { cache: false }
    headers = {}
    unless master
      opts[:use_master_key] = false
      headers["X-Parse-Master-Key"] = ""
    end
    headers["X-Parse-Session-Token"] = session_token if session_token
    Parse.client.request(method, path, body: body&.to_json, headers: headers, opts: opts)
  end

  def docker_can_reach_host?
    result = `docker exec #{ENV["PSNEXT_PREFIX"] || "psnext-it"}-server sh -c 'getent hosts host.docker.internal' 2>&1`
    !result.empty? && $?.success?
  end
end
