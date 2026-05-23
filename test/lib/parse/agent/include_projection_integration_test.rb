require_relative "../../../test_helper_integration"

# End-to-end verification that Parse Server respects dotted-path keys on
# included pointers. Confirms that the SDK's keys-on-include auto-projection
# actually shrinks the wire payload (not just the SDK envelope).
class IncludeProjectionIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  class ProjUser < Parse::Object
    parse_class "ProjUser"
    property :first_name, :string
    property :last_name, :string
    property :email, :string
    property :icon_image, :string   # stand-in for the big S3 presigned URL
    property :source_image, :string # ditto
    property :internal_tag, :string
    agent_fields :first_name, :last_name, :email, :icon_image, :source_image, :internal_tag
    agent_large_fields :icon_image, :source_image
    agent_join_fields :first_name, :last_name, :email, :internal_tag
  end

  class ProjMembership < Parse::Object
    parse_class "ProjMembership"
    property :title, :string
    property :active, :boolean
    belongs_to :user, as: :proj_user, field: :user
  end

  def test_dotted_path_keys_on_include_round_trip
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      # Seed: one user with big string payloads + a Membership pointing at them.
      big = "X" * 1500  # stand-in for an ~600-char S3 URL
      user = ProjUser.create!(
        first_name:    "Ada",
        last_name:     "Lovelace",
        email:         "ada@example.test",
        icon_image:    big,
        source_image:  big,
        internal_tag:  "vip",
      )
      ProjMembership.create!(title: "Lead", active: true, user: user)

      # Verify directly against Parse Server that dotted-path keys on
      # includes ARE honored at the wire level — uses the low-level client
      # (the same path the Agent tool uses) so we bypass Parse::Query's
      # .keys() which columnizes dotted paths and mangles them.
      raw_query = {
        where:   { active: true }.to_json,
        keys:    "title,active,user,user.firstName,user.email,user.internalTag",
        include: "user",
        limit:   1,
      }
      raw_response = Parse::Client.client.find_objects("ProjMembership", raw_query)
      raw_user = raw_response.results.first["user"]
      refute raw_user.key?("iconImage"),
        "Parse Server is supposed to respect dotted-path keys on included " \
        "pointers — wire-level test shows iconImage came back anyway. " \
        "Got keys: #{raw_user.keys.sort.inspect}"
      refute raw_user.key?("sourceImage")
      assert_equal "Ada", raw_user["firstName"]
      assert_equal "ada@example.test", raw_user["email"]
      assert_equal "vip", raw_user["internalTag"]

      # Baseline (no projection) — confirms the user payload IS bloated
      # without the dotted-path projection.
      full_response = Parse::Client.client.find_objects("ProjMembership",
        { where: { active: true }.to_json, include: "user", limit: 1 },
        cache: false)
      full_user = full_response.results.first["user"]
      assert full_user.key?("iconImage"),
        "baseline: included user with no projection should carry iconImage. " \
        "Got keys: #{full_user.keys.sort.inspect}"
      assert_equal big, full_user["iconImage"]

      # End-to-end through the Agent tool surface. This is the path the bug
      # report exercises.
      agent = Parse::Agent.new(permissions: :readonly)
      result = Parse::Agent::Tools.query_class(
        agent,
        class_name: "ProjMembership",
        where:      { active: true },
        keys:       ["user", "title", "active", "createdAt"],
        include:    ["user"],
        limit:      10,
      )
      first_row = result[:results].first
      user_obj  = first_row["user"]
      assert_kind_of Hash, user_obj, "included user must be materialized"
      refute user_obj.key?("iconImage"),
        "agent_join_fields auto-projection must strip large fields from include; " \
        "got user keys: #{user_obj.keys.sort.inspect}"
      assert user_obj.key?("firstName")
      assert_includes result[:truncated_include_fields].keys, "user"
      assert_includes result[:truncated_include_fields]["user"], "iconImage"

      # Cleanup
      ProjMembership.query(active: true).results.each(&:destroy)
      user.destroy
    end
  end
end
