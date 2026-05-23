require_relative "../../../test_helper"

class TestSession < Minitest::Test
  CORE_FIELDS = Parse::Object.fields.merge({
    created_with: :object,
    createdWith: :object,
    expires_at: :date,
    expiresAt: :date,
    installation_id: :string,
    installationId: :string,
    restricted: :boolean,
    session_token: :string,
    sessionToken: :string,
    user: :pointer,
  })

  def test_properties
    assert Parse::Session < Parse::Object
    assert_equal CORE_FIELDS, Parse::Session.fields
    # Note: :user reference uses "User" (Ruby class name) not "_User" (Parse internal name)
    # This is because belongs_to :user infers the class name from :user symbol
    assert_equal({ user: "User" }, Parse::Session.references)
    assert_empty Parse::Session.relations
    # check association methods
    assert Parse::Session.method_defined?(:user)
    assert Parse::Session.method_defined?(:installation)
  end

  def test_agent_hidden_by_default
    # _Session holds session tokens; exposing it to LLM tools risks leaking
    # credentials and lets a confused agent enumerate active sessions. Marked
    # agent_hidden in lib/parse/agent.rb after the MetadataDSL is mixed in.
    assert Parse::Session.respond_to?(:agent_hidden?), "Parse::Session should expose agent_hidden? predicate"
    assert Parse::Session.agent_hidden?, "Parse::Session should be agent_hidden by default"
  end
end
