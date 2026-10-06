require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"
require "securerandom"
require "timeout"

Parse.live_query_enabled = true
require "parse/live_query"

# LiveQuery subscriptions authorized by a `role:` grant in the class CLP.
#
# Parse Server only resolves the subscriber's roles for LiveQuery CLP checks
# when `enableLiveQueryClassLevelPermissionRoles` is on (9.10.3+, default
# false). The test stack turns it on in scripts/start-parse.sh and
# whitelists the `LiveQueryRoleProbe` class for LiveQuery. With the option
# off, the role member's subscribe below is rejected the same way the
# non-member's is.
class LiveQueryClpRolesIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  CLASS_NAME = "LiveQueryRoleProbe"
  MIN_SERVER_VERSION = "9.10.3"

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
    version = @master_client.server_version.to_s
    if version.empty? || Gem::Version.new(version[/\A[\d.]+/] || "0") < Gem::Version.new(MIN_SERVER_VERSION)
      skip "requires Parse Server #{MIN_SERVER_VERSION}+ (connected server reports #{version.inspect})"
    end

    @role_name = "LqReaders#{SecureRandom.hex(3)}"
    @member, @member_password = seed_client_user("lqr_member")
    @outsider, @outsider_password = seed_client_user("lqr_outsider")

    with_master_key do
      @role = Parse::Role.new(name: @role_name)
      @role.acl = Parse::ACL.everyone(true, false)
      @role.add_users(@member)
      assert @role.save, "role must save"
    end

    install_role_only_clp!
    @ws_url = ENV["PARSE_TEST_LIVE_QUERY_URL"] || @master_client.server_url.sub(%r{^http}, "ws")
  end

  def teardown
    @lq_client&.shutdown(timeout: 2.0) rescue nil
    with_master_key { @role&.destroy } rescue nil
    super
  end

  def test_role_member_subscribes_and_receives_events
    member_token = login_token(@member, @member_password)
    outsider_token = login_token(@outsider, @outsider_password)
    connect!

    member_events = Queue.new
    member_sub = @lq_client.subscribe(CLASS_NAME, session_token: member_token)
    member_sub.on(:create) { |obj| member_events << obj }

    outsider_sub = @lq_client.subscribe(CLASS_NAME, session_token: outsider_token)

    wait_for_settled(member_sub)
    wait_for_settled(outsider_sub)

    assert member_sub.subscribed?,
           "role member must be allowed to subscribe through a role: CLP grant " \
           "(is enableLiveQueryClassLevelPermissionRoles on?); state=#{member_sub.state}"
    assert outsider_sub.error?,
           "a user outside the role must be refused; state=#{outsider_sub.state}"

    @master_client.create_object(CLASS_NAME, { title: "role-visible", ACL: { "*" => { "read" => true } } })

    event = Timeout.timeout(10) { member_events.pop }
    refute_nil event, "role member must receive the create event"
  end

  private

  def install_role_only_clp!
    clp = {
      "find" => { "role:#{@role_name}" => true },
      "get" => { "role:#{@role_name}" => true },
      "count" => { "role:#{@role_name}" => true },
      "create" => {}, "update" => {}, "delete" => {}, "addField" => {},
    }
    schema = { className: CLASS_NAME, fields: { title: { type: "String" } }, classLevelPermissions: clp }
    response = @master_client.schema(CLASS_NAME)
    response = if response.success?
        @master_client.update_schema(CLASS_NAME, { classLevelPermissions: clp })
      else
        @master_client.create_schema(CLASS_NAME, schema)
      end
    assert response.success?, "could not install #{CLASS_NAME} CLP: #{response.inspect}"
  end

  def connect!
    @lq_client = Parse::LiveQuery::Client.new(
      url: @ws_url,
      application_id: @master_client.application_id,
      client_key: @master_client.api_key,
      master_key: nil,
      auto_connect: true,
      auto_reconnect: false,
    )
    Timeout.timeout(5) { sleep 0.05 until %i[connected closed].include?(@lq_client.state) }
    assert_equal :connected, @lq_client.state, "LiveQuery client failed to connect"
  end

  def wait_for_settled(subscription, timeout: 5)
    Timeout.timeout(timeout) { sleep 0.05 while subscription.pending? }
  rescue Timeout::Error
    nil
  end

  def login_token(user, password)
    response = @no_master_client.login(user.username, password)
    assert response.success?, "login failed: #{response.inspect}"
    response.result["sessionToken"]
  end
end
