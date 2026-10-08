require_relative "../../test_helper"
require_relative "../../support/webhook_global_state"

# The `master` flag in a webhook body is only trusted when the request came
# through authenticated ingress (webhook key or signature). Under
# `allow_unauthenticated` with no signature, any caller can claim master, so
# master-only field guards, ACL owner adoption, and handler `master?` checks
# must treat it as a non-master request. The callback dedup skip for
# SDK-originated writes also requires the authenticated claim, so a forged
# `_RB_` request id cannot suppress model callbacks.
class WebhookMasterTrustTest < Minitest::Test
  include WebhookGlobalState
  WEBHOOK_HEADER = "HTTP_X_PARSE_WEBHOOK_KEY"

  class TrustProbe < Parse::Object
    parse_class "TrustProbe"
    property :title, :string
    property :verified, :boolean
    guard :verified, :master_only

    class << self
      attr_accessor :before_save_runs
    end
    before_save { self.class.before_save_runs = (self.class.before_save_runs || 0) + 1 }
  end

  # A model whose before_save rejects every write, so a reply that succeeds
  # proves the model callbacks were skipped.
  class RejectProbe < Parse::Object
    parse_class "RejectProbe"
    property :title, :string
    before_save { throw :abort }
  end

  def setup
    ENV.delete("PARSE_SERVER_WEBHOOK_KEY")
    ENV.delete("PARSE_WEBHOOK_KEY")
    ENV.delete("PARSE_WEBHOOK_ALLOW_UNAUTHENTICATED")
    ENV.delete("PARSE_WEBHOOK_SIGNING_SECRET")
    Parse::Webhooks.instance_variable_set(:@key, nil)
    Parse::Webhooks.instance_variable_set(:@allow_unauthenticated, nil)
    Parse::Webhooks.instance_variable_set(:@routes, nil)
    Parse::Webhooks.logging = false
    Parse::Webhooks::ReplayProtection.signing_secret = nil
    Parse::Webhooks::ReplayProtection.reset!
  end

  def teardown
    Parse::Webhooks::ReplayProtection.signing_secret = nil
  end

  def build_env(body, key_header: nil, path: "/before_save/TrustProbe", headers: {})
    env = {
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE" => "application/json",
      "PATH_INFO" => path,
      "rack.input" => StringIO.new(body),
      "CONTENT_LENGTH" => body.bytesize.to_s,
    }
    env[WEBHOOK_HEADER] = key_header if key_header
    env.merge(headers)
  end

  def before_save_body(master:, object: { "className" => "TrustProbe", "title" => "t", "verified" => true }, request_id: nil)
    body = { "triggerName" => "beforeSave", "master" => master, "object" => object }
    body["headers"] = { "x-parse-request-id" => request_id } if request_id
    JSON.generate(body)
  end

  def call(env)
    result = nil
    capture_io { result = Parse::Webhooks.call(env) }
    JSON.parse(result[2].join)
  end

  def test_forged_master_is_not_trusted_on_unauthenticated_ingress
    Parse::Webhooks.allow_unauthenticated = true
    seen = nil
    Parse::Webhooks.route(:before_save, "TrustProbe") do
      seen = [master?, claimed_master?, authenticated?]
      parse_object
    end
    reply = call(build_env(before_save_body(master: true)))
    assert_equal [false, true, false], seen
    written = reply.dig("success") || {}
    refute_equal true, written["verified"],
                 "a forged master claim must not let a client write a master-only field"
  end

  def test_keyed_ingress_keeps_master
    Parse::Webhooks.key = "secret"
    seen = nil
    Parse::Webhooks.route(:before_save, "TrustProbe") do
      seen = [master?, authenticated?]
      parse_object
    end
    reply = call(build_env(before_save_body(master: true), key_header: "secret"))
    assert_equal [true, true], seen
    assert_equal true, reply.dig("success", "verified"), "a real master write keeps the guarded field"
  end

  def test_signed_ingress_without_key_keeps_master
    Parse::Webhooks.allow_unauthenticated = true
    secret = "sign-secret"
    Parse::Webhooks::ReplayProtection.signing_secret = secret
    body = before_save_body(master: true)
    ts = Time.now.to_i.to_s
    sig = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{ts}.#{body}")
    headers = {
      Parse::Webhooks::ReplayProtection::HEADER_TIMESTAMP => ts,
      Parse::Webhooks::ReplayProtection::HEADER_SIGNATURE => sig,
    }
    seen = nil
    Parse::Webhooks.route(:before_save, "TrustProbe") { seen = master?; parse_object }
    call(build_env(body, headers: headers))
    assert_equal true, seen, "a verified signature authenticates the request"
  end

  def signed_headers(secret, body, signature: nil)
    ts = Time.now.to_i.to_s
    {
      Parse::Webhooks::ReplayProtection::HEADER_TIMESTAMP => ts,
      Parse::Webhooks::ReplayProtection::HEADER_SIGNATURE => signature || OpenSSL::HMAC.hexdigest("SHA256", secret, "#{ts}.#{body}"),
    }
  end

  def test_key_match_with_bad_signature_is_rejected
    Parse::Webhooks.key = "secret"
    Parse::Webhooks::ReplayProtection.signing_secret = "sign-secret"
    ran = false
    Parse::Webhooks.route(:before_save, "TrustProbe") { ran = true; parse_object }
    body = before_save_body(master: true)
    reply = call(build_env(body, key_header: "secret", headers: signed_headers("sign-secret", body, signature: "0" * 64)))
    refute ran, "a bad signature must reject the request even when the key matches"
    assert_match(/signature/i, reply["error"].to_s)
  end

  def test_key_and_signature_both_valid_keep_master
    Parse::Webhooks.key = "secret"
    Parse::Webhooks::ReplayProtection.signing_secret = "sign-secret"
    seen = nil
    Parse::Webhooks.route(:before_save, "TrustProbe") { seen = [master?, authenticated?]; parse_object }
    body = before_save_body(master: true)
    call(build_env(body, key_header: "secret", headers: signed_headers("sign-secret", body)))
    assert_equal [true, true], seen
  end

  def test_signed_request_without_key_is_refused_when_unauthenticated_is_off
    Parse::Webhooks::ReplayProtection.signing_secret = "sign-secret"
    ran = false
    Parse::Webhooks.route(:before_save, "TrustProbe") { ran = true; parse_object }
    body = before_save_body(master: true)
    reply = call(build_env(body, headers: signed_headers("sign-secret", body)))
    refute ran, "a signing secret alone does not admit requests without a key"
    refute_nil reply["error"]
  end

  def test_replay_check_reports_signature_verification
    Parse::Webhooks::ReplayProtection.signing_secret = "sign-secret"
    body = before_save_body(master: true)
    env = build_env(body, headers: signed_headers("sign-secret", body))
    assert_equal [nil, true], Parse::Webhooks::ReplayProtection.check(env, body, nil)
    Parse::Webhooks::ReplayProtection.signing_secret = nil
    assert_equal [nil, false], Parse::Webhooks::ReplayProtection.check(build_env(body), body, nil)
  end

  def reject_body(master:, request_id:)
    before_save_body(master: master, request_id: request_id,
                     object: { "className" => "RejectProbe", "title" => "t" })
  end

  def test_forged_ruby_initiated_claim_does_not_skip_callbacks
    Parse::Webhooks.allow_unauthenticated = true
    Parse::Webhooks.route(:before_save, "RejectProbe") { parse_object }
    reply = call(build_env(reject_body(master: true, request_id: "_RB_forged"),
                           path: "/before_save/RejectProbe"))
    assert reply.key?("error"), "a forged _RB_ id plus master must not skip a rejecting before_save (got #{reply.inspect})"
    refute reply.key?("success")
    # The same request without the marker is rejected the same way.
    reply = call(build_env(reject_body(master: true, request_id: "client-1"),
                           path: "/before_save/RejectProbe"))
    assert reply.key?("error")
  end

  def test_forged_ruby_initiated_claim_runs_counting_callbacks
    Parse::Webhooks.allow_unauthenticated = true
    Parse::Webhooks.route(:before_save, "TrustProbe") { parse_object }
    TrustProbe.before_save_runs = 0
    call(build_env(before_save_body(master: true, request_id: "_RB_abc")))
    assert_equal 1, TrustProbe.before_save_runs,
                 "unauthenticated ingress cannot claim the Ruby-initiated dedup"
  end

  def test_authenticated_ruby_initiated_write_keeps_dedup
    Parse::Webhooks.key = "secret"
    Parse::Webhooks.route(:before_save, "RejectProbe") { parse_object }
    reply = call(build_env(reject_body(master: true, request_id: "_RB_abc"),
                           key_header: "secret", path: "/before_save/RejectProbe"))
    assert reply.key?("success"), "an authenticated SDK-originated write skips the duplicate callback pass (got #{reply.inspect})"
    Parse::Webhooks.route(:before_save, "TrustProbe") { parse_object }
    TrustProbe.before_save_runs = 0
    call(build_env(before_save_body(master: true, request_id: "_RB_abc"), key_header: "secret"))
    assert_equal 0, TrustProbe.before_save_runs
    call(build_env(before_save_body(master: true, request_id: "client-1"), key_header: "secret"))
    assert_equal 1, TrustProbe.before_save_runs, "a non-SDK write still runs model callbacks"
  end

  def test_acl_owner_adoption_treats_forged_master_as_non_master
    Parse::Webhooks.allow_unauthenticated = true
    payload = Parse::Webhooks::Payload.new(before_save_body(master: true))
    payload.authenticated = false
    refute payload.master?
    payload.authenticated = true
    assert payload.master?
  end

  def test_string_false_is_not_master
    payload = Parse::Webhooks::Payload.new(JSON.generate("triggerName" => "beforeSave", "master" => "false"))
    refute payload.master?
    refute payload.claimed_master?
    assert Parse::Webhooks::Payload.new(JSON.generate("triggerName" => "beforeSave", "master" => true)).master?
  end

  def test_only_json_true_is_master
    %w[true 1 yes].each do |raw|
      payload = Parse::Webhooks::Payload.new(JSON.generate("triggerName" => "beforeSave", "master" => raw))
      refute payload.claimed_master?, "string #{raw.inspect} must not count as master"
      refute payload.master?
    end
    refute Parse::Webhooks::Payload.new(JSON.generate("triggerName" => "beforeSave", "master" => 1)).master?
  end

  def test_in_process_payload_is_authenticated_by_default
    assert Parse::Webhooks::Payload.new.authenticated?
  end
end
