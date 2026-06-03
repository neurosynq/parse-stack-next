require_relative "../../../test_helper"

class TestInstallation < Minitest::Test
  CORE_FIELDS = Parse::Object.fields.merge({
    :id => :string,
    :created_at => :date,
    :updated_at => :date,
    :acl => :acl,
    :objectId => :string,
    :createdAt => :date,
    :updatedAt => :date,
    :ACL => :acl,
    :gcm_sender_id => :string,
    :GCMSenderId => :string,
    :app_identifier => :string,
    :appIdentifier => :string,
    :app_name => :string,
    :appName => :string,
    :app_version => :string,
    :appVersion => :string,
    :app_build_number => :string,
    :appBuildNumber => :string,
    :badge => :integer,
    :channels => :array,
    :device_token => :string,
    :deviceToken => :string,
    :device_token_last_modified => :integer,
    :deviceTokenLastModified => :integer,
    :device_type => :string,
    :deviceType => :string,
    :installation_id => :string,
    :installationId => :string,
    :locale_identifier => :string,
    :localeIdentifier => :string,
    :parse_version => :string,
    :parseVersion => :string,
    :push_type => :string,
    :pushType => :string,
    :time_zone => :timezone,
    :timeZone => :timezone,
    :user => :pointer,
  })

  def test_properties
    assert Parse::Installation < Parse::Object
    assert_equal CORE_FIELDS, Parse::Installation.fields
    # `belongs_to :user` resolves to the Parse storage class name "_User",
    # which is what gets pushed to the schema as the pointer targetClass.
    assert_equal({ user: Parse::Model::CLASS_USER }, Parse::Installation.references)
    assert_equal "Pointer", Parse::Installation.schema[:fields][:user][:type]
    assert_equal Parse::Model::CLASS_USER, Parse::Installation.schema[:fields][:user][:targetClass]
    assert_empty Parse::Installation.relations
    assert Parse::Installation.method_defined?(:session)
    assert Parse::Installation.method_defined?(:user)
  end

  # ─── _Installation CLP advisory: operation-aware ───────────────────────
  # Parse Server ignores CLP for find/create/update/delete on _Installation
  # but honors it for get/count/addField. The advisory must warn only for
  # the operations the server ignores.

  def test_installation_clp_ineffective_predicate
    %i[find create update delete].each do |op|
      assert Parse::Installation.send(:_installation_clp_ineffective?, op), "#{op} should be ineffective"
    end
    %i[get count addField].each do |op|
      refute Parse::Installation.send(:_installation_clp_ineffective?, op), "#{op} should be effective"
    end
    # String / Symbol normalization
    assert Parse::Installation.send(:_installation_clp_ineffective?, "find")
    refute Parse::Installation.send(:_installation_clp_ineffective?, "count")
  end

  def test_installation_clp_advisory_silent_for_effective_operations
    %i[get count addField].each do |op|
      out = capture_installation_clp { Parse::Installation.set_clp(op) }
      refute_match(/\[Parse::Installation\]/, out, "set_clp(#{op}) must not warn")
    end
  end

  def test_installation_clp_advisory_warns_for_ineffective_operations
    %i[find create update delete].each do |op|
      out = capture_installation_clp { Parse::Installation.set_clp(op) }
      assert_match(/\[Parse::Installation\]/, out, "set_clp(#{op}) must warn")
    end
  end

  def test_installation_clp_advisory_set_class_access_filters_by_operation
    silent = capture_installation_clp { Parse::Installation.set_class_access(get: :authenticated, count: :master) }
    refute_match(/\[Parse::Installation\]/, silent, "get+count must not warn")

    warned = capture_installation_clp { Parse::Installation.set_class_access(get: :authenticated, delete: :master) }
    assert_match(/\[Parse::Installation\]/, warned, "an ineffective op among the keys must warn")
  end

  private

  # Capture the one-time CLP advisory while isolating the mutation: reset the
  # one-shot warned flag, snapshot/restore class_permissions (set_clp mutates
  # it), and capture Parse.logger output.
  def capture_installation_clp
    io = StringIO.new
    prev_logger = Parse.logger
    prev_clp = Parse::Installation.instance_variable_get(:@class_permissions)
    Parse.logger = Logger.new(io)
    Parse::Installation.instance_variable_set(:@_installation_clp_warned, false)
    yield
    io.string
  ensure
    Parse.logger = prev_logger
    Parse::Installation.instance_variable_set(:@class_permissions, prev_clp)
    Parse::Installation.instance_variable_set(:@_installation_clp_warned, false)
  end
end
