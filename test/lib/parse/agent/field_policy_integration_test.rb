# encoding: UTF-8
# frozen_string_literal: true

# End-to-end check of per-agent field narrowing against a live Parse Server:
# a signed-in user can read a field directly through Parse, but a narrower
# MCP deployment (session-token agent with `fields:`) hides it, refuses
# filtering on it, and a broader analytics deployment in the same process can
# still expose it within the class ceiling.
#
# Gated on PARSE_TEST_USE_DOCKER=true.

require_relative "../../../test_helper_integration"
require "securerandom"
require "parse/agent"

class FieldPolicyIntegrationCustomer < Parse::Object
  parse_class "FieldPolicyIntegrationCustomer"
  property :display_name, :string
  property :timezone, :string
  property :plan, :string
  agent_fields :display_name, :timezone, :plan
end

class AgentFieldPolicyIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def silence_master_key
    was = Parse::Agent.suppress_master_key_warning
    Parse::Agent.suppress_master_key_warning = true
    yield
  ensure
    Parse::Agent.suppress_master_key_warning = was unless was.nil?
  end

  def test_narrower_deployment_hides_what_the_user_and_analytics_can_read
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      suffix = SecureRandom.hex(4)
      password = "pw-#{suffix}!"
      Parse::User.signup("fp_user_#{suffix}", password, "fp_#{suffix}@example.test")
      user = Parse::User.login("fp_user_#{suffix}", password)
      token = user&.session_token
      refute_nil token

      row = FieldPolicyIntegrationCustomer.new(display_name: "Ada #{suffix}", timezone: "UTC", plan: "pro")
      row.acl = Parse::ACL.new
      row.acl.apply(user.id, true, true)
      row.save

      # The user can read `plan` directly through Parse.
      direct = FieldPolicyIntegrationCustomer.query(objectId: row.id).tap { |q| q.session_token = token }.results.first
      assert_equal "pro", direct.plan

      # A narrower user-facing deployment does not expose it.
      assistant = Parse::Agent.new(session_token: token,
                                   fields: { FieldPolicyIntegrationCustomer => %i[display_name timezone] })
      r = assistant.execute(:query_class, class_name: "FieldPolicyIntegrationCustomer",
                                          where: { "objectId" => row.id })
      assert r[:success], r[:error].to_s
      record = r[:data][:results].first
      assert_equal "Ada #{suffix}", record["displayName"]
      refute record.key?("plan"), "the narrowed deployment must not return plan"

      # ...and refuses to filter on it, so its value cannot be inferred.
      r = assistant.execute(:count_objects, class_name: "FieldPolicyIntegrationCustomer", where: { "plan" => "pro" })
      refute r[:success]
      assert_equal :field_denied, r.dig(:details, :kind)

      # A broader analytics deployment in the same process can expose it.
      analytics = silence_master_key do
        Parse::Agent.new(permissions: :readonly,
                         fields: { FieldPolicyIntegrationCustomer => %i[display_name plan] })
      end
      r = analytics.execute(:query_class, class_name: "FieldPolicyIntegrationCustomer",
                                          where: { "objectId" => row.id })
      assert r[:success], r[:error].to_s
      assert_equal "pro", r[:data][:results].first["plan"]
      refute r[:data][:results].first.key?("timezone"), "analytics narrows timezone away"
    ensure
      row&.destroy rescue nil
      user&.destroy rescue nil
    end
  end
end
