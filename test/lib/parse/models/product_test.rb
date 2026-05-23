require_relative "../../../test_helper"

class ProductModelTest < Minitest::Test
  CORE_FIELDS = Parse::Object.fields.merge({
    :id => :string,
    :created_at => :date,
    :updated_at => :date,
    :acl => :acl,
    :objectId => :string,
    :createdAt => :date,
    :updatedAt => :date,
    :ACL => :acl,
    :download => :file,
    :download_name => :string,
    :downloadName => :string,
    :icon => :file,
    :order => :integer,
    :product_identifier => :string,
    :productIdentifier => :string,
    :subtitle => :string,
    :title => :string,
  })

  def test_properties
    assert Parse::Product < Parse::Object
    assert_equal CORE_FIELDS, Parse::Product.fields
    assert_empty Parse::Product.references
    assert_empty Parse::Product.relations
  end

  def test_agent_hidden_by_default
    # The _Product collection is a vestigial Parse iOS IAP feature and almost
    # no modern application uses it; expose-by-default for the agent surface
    # just adds noise. Marked agent_hidden in lib/parse/agent.rb after the
    # MetadataDSL is mixed into Parse::Object.
    assert Parse::Product.respond_to?(:agent_hidden?), "Parse::Product should expose agent_hidden? predicate"
    assert Parse::Product.agent_hidden?, "Parse::Product should be agent_hidden by default"
  end

  def test_agent_unhidden_reverses_default
    # Applications that actually use _Product can re-expose it on the agent
    # surface by calling Parse::Product.agent_unhidden at boot time. The call
    # emits a one-line audit banner; silence it here so the test output is
    # clean while still exercising the real code path.
    assert Parse::Product.agent_hidden?
    assert_includes Parse::Agent::MetadataRegistry.hidden_class_names, Parse::Product.parse_class
    suppress_was = Parse::Agent.suppress_master_key_warning
    Parse::Agent.suppress_master_key_warning = true
    Parse::Product.agent_unhidden
    refute Parse::Product.agent_hidden?, "agent_unhidden should clear the hidden flag"
    refute_includes Parse::Agent::MetadataRegistry.hidden_class_names, Parse::Product.parse_class
  ensure
    Parse::Product.agent_hidden
    Parse::Agent.suppress_master_key_warning = suppress_was unless suppress_was.nil?
  end
end
