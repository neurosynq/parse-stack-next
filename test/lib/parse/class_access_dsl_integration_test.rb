require_relative "../../test_helper_integration"

# End-to-end verification that the class-level access DSL shortcuts
# (master_only_class!, unlistable_class!, set_class_access) actually push
# the right Class Level Permissions to Parse Server, and that Parse Server
# then enforces them as expected for non-master clients.

class ClassAccessMasterOnly < Parse::Object
  parse_class "ClassAccessMasterOnly"
  property :note, :string
  master_only_class!
end

class ClassAccessInstallationStyle < Parse::Object
  parse_class "ClassAccessInstallationStyle"
  property :token, :string
  # Installation-style: clients can create + get-by-id, but cannot list/enumerate.
  # Update/delete are master-only so even a malicious client with the id
  # can't tamper.
  set_class_access(
    find:   :master,
    count:  :master,
    get:    :public,
    create: :public,
    update: :master,
    delete: :master,
  )
end

module ClassAccessDslSetup
  # Prepended so `super` reaches the `define_method :setup` installed by
  # ParseStackIntegrationTest (which performs Parse.setup and DB reset).
  # A plain `def setup` on the test class would shadow it and `super`
  # would skip to Minitest::Test#setup.
  def setup
    super
    ClassAccessMasterOnly.auto_upgrade!(include_clp: false)
    ClassAccessMasterOnly.update_clp!
    ClassAccessInstallationStyle.auto_upgrade!(include_clp: false)
    ClassAccessInstallationStyle.update_clp!
  end
end

class ClassAccessDslEndToEndIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  prepend ClassAccessDslSetup

  def test_master_only_class_blocks_non_master_find
    response = non_master_get("classes/ClassAccessMasterOnly")
    assert response.error?,
           "master_only_class! must block non-master `find`. " \
           "Got: status=#{response.code.inspect} result=#{response.result.inspect}"
  end

  def test_master_only_class_blocks_non_master_create
    response = non_master_post("classes/ClassAccessMasterOnly", { "note" => "should-fail" })
    assert response.error?,
           "master_only_class! must block non-master `create`. " \
           "Got: status=#{response.code.inspect} result=#{response.result.inspect}"
  end

  def test_master_can_still_read_master_only_class
    # The server still talks to us when we use the master key.
    master_post("classes/ClassAccessMasterOnly", { "note" => "by master" })
    response = Parse.client.request(:get, "classes/ClassAccessMasterOnly")
    refute response.error?, "master key bypasses master_only_class!"
  end

  def test_installation_style_class_blocks_non_master_find
    # Even though clients can create and get-by-id, they cannot enumerate.
    response = non_master_get("classes/ClassAccessInstallationStyle")
    assert response.error?,
           "find should be blocked by set_class_access(find: :master). " \
           "Got: status=#{response.code.inspect} result=#{response.result.inspect}"
  end

  def test_installation_style_class_allows_non_master_create_and_get
    # Non-master creates a record
    create_response = non_master_post("classes/ClassAccessInstallationStyle",
                                       { "token" => "client-installed" })
    refute create_response.error?,
           "create should succeed for set_class_access(create: :public). " \
           "Got: status=#{create_response.code.inspect} result=#{create_response.result.inspect}"
    object_id = create_response.result["objectId"]
    refute_nil object_id, "create must return an objectId"

    # And can fetch by id
    get_response = non_master_get("classes/ClassAccessInstallationStyle/#{object_id}")
    refute get_response.error?,
           "get-by-id should succeed for set_class_access(get: :public). " \
           "Got: status=#{get_response.code.inspect} result=#{get_response.result.inspect}"
    assert_equal "client-installed", get_response.result["token"]
  end

  def test_installation_style_class_blocks_non_master_update
    # Master creates a record
    create_response = master_post("classes/ClassAccessInstallationStyle",
                                   { "token" => "original" })
    object_id = create_response.result["objectId"]

    # Non-master tries to update -- should be blocked by update: :master
    update_response = non_master_put(
      "classes/ClassAccessInstallationStyle/#{object_id}",
      { "token" => "client-tampered" },
    )
    assert update_response.error?,
           "update should be blocked by set_class_access(update: :master). " \
           "Got: status=#{update_response.code.inspect} result=#{update_response.result.inspect}"

    # And the persisted value is unchanged
    fetched = Parse.client.request(:get, "classes/ClassAccessInstallationStyle/#{object_id}").result
    assert_equal "original", fetched["token"], "update must not have persisted"
  end

  private

  def non_master_get(path)
    Parse.client.request(
      :get, path,
      headers: { "X-Parse-Master-Key" => "" },
      opts: { use_master_key: false },
    )
  end

  def non_master_post(path, body)
    Parse.client.request(
      :post, path,
      body: body.to_json,
      headers: { "X-Parse-Master-Key" => "" },
      opts: { use_master_key: false },
    )
  end

  def non_master_put(path, body)
    Parse.client.request(
      :put, path,
      body: body.to_json,
      headers: { "X-Parse-Master-Key" => "" },
      opts: { use_master_key: false },
    )
  end

  def master_post(path, body)
    Parse.client.request(:post, path, body: body.to_json)
  end
end
