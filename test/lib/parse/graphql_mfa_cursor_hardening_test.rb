# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "open3"
require "parse/graphql"

# Covers the GraphQL credential denylist, MFA username validation, TOTP
# replay rejection, signed cursor state, and the parse-console master key
# warning.
class GraphQLMFACursorHardeningTest < Minitest::Test
  unless defined?(HardenedGqlAccount)
    class HardenedGqlAccount < Parse::Object
      parse_class "HardenedGqlAccount"
      property :title, :string
      property :session_token, :string
      property :auth_data, :object
      property :password, :string
      property :device_token, :string
      property :secret_note, :string
      property :email, :string
    end

    class HardenedGqlPost < Parse::Object
      parse_class "HardenedGqlPost"
      property :title, :string
      property :category, :string
    end
  end

  def teardown
    Parse::CLPScope.reset_cache!
    Parse::Cursor.signing_secret = nil
    Parse::Cursor.reset_unsigned_warning!
  end

  def field_names(type)
    type.fields.keys.map(&:to_s)
  end

  # ----------------------------------------------------------------
  # GraphQL type generator
  # ----------------------------------------------------------------

  def test_credential_fields_are_never_emitted
    type = Parse::GraphQL::TypeGenerator.generate(HardenedGqlAccount)
    names = field_names(type)
    assert_includes names, "title"
    %w[sessionToken authData password deviceToken].each do |f|
      refute_includes names, f, "#{f} must not be emitted"
    end
  end

  def test_include_sensitive_opts_in_a_denied_field
    type = Parse::GraphQL::TypeGenerator.generate(HardenedGqlAccount, include_sensitive: [:device_token])
    names = field_names(type)
    assert_includes names, "deviceToken"
    refute_includes names, "sessionToken"
  end

  def test_output_does_not_depend_on_clp_cache
    cold = field_names(Parse::GraphQL::TypeGenerator.generate(HardenedGqlAccount))
    Parse::CLPScope.__cache_put("HardenedGqlAccount",
                                clp: { "find" => { "*" => true },
                                       "protectedFields" => { "*" => ["secretNote"] } })
    warm = field_names(Parse::GraphQL::TypeGenerator.generate(HardenedGqlAccount, registry: {}))
    assert_equal cold.sort, warm.sort
    assert_includes warm, "secretNote"
    excluded = field_names(Parse::GraphQL::TypeGenerator.generate(HardenedGqlAccount, registry: {},
                                                                                       exclude_fields: [:secret_note]))
    refute_includes excluded, "secretNote"
  end

  def test_default_performs_no_protected_fields_lookup
    calls = 0
    Parse::CLPScope.stub(:protected_fields_for, ->(*) { calls += 1; Set.new }) do
      Parse::CLPScope.stub(:evaluate_access, ->(*, **) { calls += 1; nil }) do
        Parse::GraphQL::TypeGenerator.generate(HardenedGqlPost)
      end
    end
    assert_equal 0, calls
  end

  def test_server_default_protected_fields_are_not_applied_implicitly
    Parse::CLPScope.default_protected_fields = { "HardenedGqlPost" => { "*" => ["category"] } }
    assert_includes field_names(Parse::GraphQL::TypeGenerator.generate(HardenedGqlPost)), "category"
  ensure
    Parse::CLPScope.default_protected_fields = nil
  end

  def test_exclude_fields_array_and_hash
    names = field_names(Parse::GraphQL::TypeGenerator.generate(HardenedGqlAccount, exclude_fields: ["secretNote", :email]))
    refute_includes names, "secretNote"
    refute_includes names, "email"
    assert_includes names, "title"

    registry = Parse::GraphQL::TypeGenerator.generate_all([HardenedGqlAccount, HardenedGqlPost],
                                                          exclude_fields: [:title])
    refute_includes field_names(registry["HardenedGqlAccount"]), "title"
    refute_includes field_names(registry["HardenedGqlPost"]), "title"

    registry = Parse::GraphQL::TypeGenerator.generate_all(
      [HardenedGqlAccount, HardenedGqlPost],
      exclude_fields: { "HardenedGqlAccount" => [:secret_note], HardenedGqlPost => [:category] },
    )
    refute_includes field_names(registry["HardenedGqlAccount"]), "secretNote"
    assert_includes field_names(registry["HardenedGqlAccount"]), "title"
    refute_includes field_names(registry["HardenedGqlPost"]), "category"
  end

  def test_exclude_fields_wins_over_include_sensitive
    names = field_names(Parse::GraphQL::TypeGenerator.generate(HardenedGqlAccount, include_sensitive: [:device_token],
                                                                                   exclude_fields: [:device_token]))
    refute_includes names, "deviceToken"
  end

  def test_protected_fields_hash
    registry = Parse::GraphQL::TypeGenerator.generate_all(
      [HardenedGqlAccount, HardenedGqlPost],
      protected_fields: { "HardenedGqlAccount" => ["secretNote"] },
    )
    refute_includes field_names(registry["HardenedGqlAccount"]), "secretNote"
    assert_includes field_names(registry["HardenedGqlPost"]), "category"

    names = field_names(Parse::GraphQL::TypeGenerator.generate(HardenedGqlPost, protected_fields: { HardenedGqlPost => [:category] },
                                                                                include_sensitive: [:category]))
    assert_includes names, "category"
  end

  def test_protected_fields_rejects_unknown_option
    assert_raises(ArgumentError) { Parse::GraphQL::TypeGenerator.generate(HardenedGqlPost, protected_fields: true) }
  end

  def test_protected_fields_fetch_uses_clp_scope
    seen = []
    resolved = Parse::CLPScope::AccessEvaluation.new(status: :allowed)
    Parse::CLPScope.stub(:evaluate_access, ->(*, **) { resolved }) do
      Parse::CLPScope.stub(:protected_fields_for, ->(name, perms, **kw) { seen << [name, perms, kw]; Set["secretNote"] }) do
        names = field_names(Parse::GraphQL::TypeGenerator.generate(HardenedGqlAccount, protected_fields: :fetch))
        refute_includes names, "secretNote"
        assert_includes names, "title"
      end
    end
    assert_equal [["HardenedGqlAccount", ["*"], { strict: true }]], seen
  end

  def test_protected_fields_fetch_raises_when_lookup_raises
    resolved = Parse::CLPScope::AccessEvaluation.new(status: :allowed)
    Parse::CLPScope.stub(:evaluate_access, ->(*, **) { resolved }) do
      Parse::CLPScope.stub(:protected_fields_for, ->(*) { raise "schema request failed" }) do
        err = assert_raises(Parse::GraphQL::TypeGenerator::ProtectedFieldsUnavailable) do
          Parse::GraphQL::TypeGenerator.generate(HardenedGqlAccount, protected_fields: :fetch)
        end
        assert_match(/schema request failed/, err.message)
      end
    end
  end

  def test_protected_fields_fetch_raises_when_clp_unresolvable
    unresolved = Parse::CLPScope::AccessEvaluation.new(status: :unknown, reason: :clp_unresolvable)
    Parse::CLPScope.stub(:evaluate_access, ->(*, **) { unresolved }) do
      Parse::CLPScope.stub(:protected_fields_for, ->(*) { Set.new }) do
        assert_raises(Parse::GraphQL::TypeGenerator::ProtectedFieldsUnavailable) do
          Parse::GraphQL::TypeGenerator.generate(HardenedGqlAccount, protected_fields: :fetch)
        end
      end
    end
  end

  def test_user_type_emits_email_unless_excluded_or_protected
    models = [Parse::User, Parse::Session, Parse::Installation, Parse::Role]
    registry = Parse::GraphQL::TypeGenerator.generate_all(models)
    names = field_names(registry["_User"])
    assert_includes names, "email"
    refute_includes names, "authData"
    refute_includes field_names(registry["_Session"]), "sessionToken"

    excluded = Parse::GraphQL::TypeGenerator.generate_all(models, exclude_fields: { "_User" => [:email] })
    refute_includes field_names(excluded["_User"]), "email"

    protected_ = Parse::GraphQL::TypeGenerator.generate_all(models, protected_fields: { Parse::User => ["email"] })
    refute_includes field_names(protected_["_User"]), "email"
  end

  # ----------------------------------------------------------------
  # MFA username validation
  # ----------------------------------------------------------------

  def test_mfa_required_rejects_hash_username
    assert_raises(ArgumentError) { Parse::User.mfa_required?({ "$regex" => "^a" }) }
    assert_raises(ArgumentError) { Parse::User.mfa_required?(nil) }
    assert_raises(ArgumentError) { Parse::User.mfa_required?("   ") }
  end

  def test_mfa_required_strips_string_username
    seen = nil
    fake = Struct.new(:first).new(nil)
    Parse::User.stub(:where, ->(c) { seen = c; fake }) do
      refute Parse::User.mfa_required?("  john  ")
    end
    assert_equal({ username: "john" }, seen)
  end

  def test_login_with_mfa_rejects_hash_username
    assert_raises(ArgumentError) { Parse::User.login_with_mfa({ "$ne" => "" }, "pw", "123456") }
  end

  # ----------------------------------------------------------------
  # TOTP replay
  # ----------------------------------------------------------------

  def test_verify_after_rejects_reuse
    Parse::MFA.instance_variable_set(:@config, nil)
    secret = Parse::MFA.generate_secret
    code = Parse::MFA.current_code(secret)
    ts = Parse::MFA.verify_timestamp(secret, code)
    assert_kind_of Integer, ts
    assert Parse::MFA.verify(secret, code), "default behavior unchanged"
    refute Parse::MFA.verify(secret, code, after: ts)
    assert_nil Parse::MFA.verify_timestamp(secret, code, after: Time.at(ts))
    assert Parse::MFA.verify(secret, code, after: ts - 120)
  end

  def test_verify_after_rejects_bad_type
    secret = Parse::MFA.generate_secret
    assert_raises(ArgumentError) { Parse::MFA.verify(secret, "123456", after: "yesterday") }
  end

  # ----------------------------------------------------------------
  # Cursor signing
  # ----------------------------------------------------------------

  def build_cursor
    Parse::Cursor.new(HardenedGqlPost.query(category: "news"), limit: 10)
  end

  def test_signed_round_trip
    token = build_cursor.serialize(secret: "s3cret-kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk")
    assert JSON.parse(token).key?("sig")
    cursor = Parse::Cursor.deserialize(token, secret: "s3cret-kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk", expected_class: HardenedGqlPost)
    assert_equal "HardenedGqlPost", cursor.query.table
    assert_equal 10, cursor.page_size
  end

  def test_global_secret_signs_and_verifies
    Parse::Cursor.signing_secret = "global-kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk"
    token = build_cursor.to_json
    assert Parse::Cursor.deserialize(token)
  end

  def test_tampered_state_is_refused
    token = JSON.parse(build_cursor.serialize(secret: "s3cret-kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk"))
    state = JSON.parse(token["state"])
    state["class_name"] = "_User"
    token["state"] = JSON.generate(state)
    err = assert_raises(ArgumentError) { Parse::Cursor.deserialize(JSON.generate(token), secret: "s3cret-kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk") }
    assert_match(/signature/, err.message)
  end

  def test_wrong_secret_is_refused
    token = build_cursor.serialize(secret: "a" * 32)
    assert_raises(ArgumentError) { Parse::Cursor.deserialize(token, secret: "b" * 32) }
  end

  def test_unsigned_refused_when_secret_configured
    token = build_cursor.serialize
    assert_raises(ArgumentError) { Parse::Cursor.deserialize(token, secret: "s3cret-kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk") }
  end

  def test_signed_token_without_secret_is_refused
    token = build_cursor.serialize(secret: "s3cret-kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk")
    assert_raises(ArgumentError) { Parse::Cursor.deserialize(token) }
  end

  def test_unsigned_still_works_and_warns_once
    token = build_cursor.serialize
    _out, err = capture_io do
      Parse::Cursor.deserialize(token)
      Parse::Cursor.deserialize(token)
    end
    assert_equal 1, err.scan("unsigned cursor").size
  end

  def test_expected_class_mismatch_is_refused
    token = build_cursor.serialize(secret: "s3cret-kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk")
    err = assert_raises(ArgumentError) do
      Parse::Cursor.deserialize(token, secret: "s3cret-kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk", expected_class: HardenedGqlAccount)
    end
    assert_match(/expected "HardenedGqlAccount"/, err.message)
    assert_raises(ArgumentError) do
      Parse::Cursor.deserialize(token, secret: "s3cret-kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk", expected_class: "_User")
    end
  end

  def test_deep_nesting_is_refused
    deep = ("[" * 50) + ("]" * 50)
    assert_raises(ArgumentError) { capture_io { Parse::Cursor.deserialize(deep) } }
  end

  # ----------------------------------------------------------------
  # parse-console
  # ----------------------------------------------------------------

  def test_parse_console_warns_on_master_key_flag
    bin = File.expand_path("../../../bin/parse-console", __dir__)
    _out, err, status = Open3.capture3(RbConfig.ruby, "-Ilib", bin, "-m", "secretkey")
    refute status.success?
    assert_match(/exposes it in the process list/, err)
    assert_match(/-c CONFIG_JSON/, err)
  end
end
