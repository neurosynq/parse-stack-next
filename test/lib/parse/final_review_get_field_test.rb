# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/mongodb"
require "parse/pipeline_security"
require "parse/clp_scope"
require "parse/acl_scope"

# A `$getField` whose field name is computed at run time can read a
# protected column under another name. `{ $getField: "$selector" }` takes
# the name from the document's own `selector` field, so a caller who first
# sets `selector` to "secret" exposes the protected value. For a scoped
# caller on a class with protected fields, only a plain field name (or a
# `$literal` naming a non-protected field) is allowed.
class FinalReviewGetFieldTest < Minitest::Test
  class FakeCollection
    attr_reader :pipelines

    def initialize
      @pipelines = []
    end

    def aggregate(pipeline, _opts = {})
      @pipelines << pipeline
      []
    end

    def with(*)
      self
    end
  end

  def setup
    Parse.setup(server_url: "http://localhost:1337/parse",
                application_id: "test", api_key: "test") unless Parse::Client.client?
    Parse::CLPScope.reset_cache!
    Parse::CLPScope.default_protected_fields = nil
  end

  def teardown
    Parse::CLPScope.reset_cache!
    Parse::CLPScope.default_protected_fields = nil
  end

  def scoped
    Parse::ACLScope::Resolution.new(mode: :session, permission_strings: ["*", "u1"],
                                    user_id: "u1", session: nil, client: nil)
  end

  def master
    Parse::ACLScope::Resolution.new(mode: :master, permission_strings: nil, user_id: nil,
                                    session: nil, client: nil)
  end

  def run_aggregate(class_name, pipeline, resolution)
    coll = FakeCollection.new
    Parse::ACLScope.stub(:resolve!, ->(*_a, **_k) { resolution }) do
      Parse::MongoDB.stub(:collection, ->(*_a, **_k) { coll }) do
        Parse::MongoDB.aggregate(class_name, pipeline, session_token: "r:stub")
      end
    end
    coll.pipelines.last
  end

  def protect_secret!(klass = "FRItem")
    Parse::CLPScope.__cache_put(klass, clp: {
      "find" => { "*" => true }, "count" => { "*" => true },
      "protectedFields" => { "*" => ["secret"] },
    })
  end

  def refused?(pipeline, klass = "FRItem")
    run_aggregate(klass, pipeline, scoped)
    false
  rescue Parse::CLPScope::Denied
    true
  end

  def test_dollar_prefixed_get_field_name_is_refused
    protect_secret!
    pipeline = [
      { "$addFields" => { "selector" => "secret" } },
      { "$project" => { "leak" => { "$getField" => "$selector" } } },
    ]
    assert refused?(pipeline), "a $getField name read from the document must be refused"
  end

  def test_computed_get_field_name_forms_are_refused
    protect_secret!
    [
      { "$getField" => { "field" => "$selector" } },
      { "$getField" => { "field" => "$selector", "input" => "$$ROOT" } },
      { "$getField" => { "field" => "$selector", "input" => "$other" } },
      { "$getField" => { "field" => { "$toString" => "$selector" } } },
      { "$getField" => { "field" => { "$literal" => "secret" } } },
      { "$getField" => { "field" => { "$literal" => { "$concat" => ["sec", "ret"] } } } },
      { "$getField" => :$selector },
      { "$getField" => nil },
    ].each do |expr|
      assert refused?([{ "$project" => { "leak" => expr } }]), "expected refusal for #{expr.inspect}"
    end
  end

  def test_computed_name_inside_match_expr_is_refused
    protect_secret!
    pipeline = [{ "$match" => { "$expr" => { "$eq" => [{ "$getField" => "$selector" }, "x"] } } }]
    assert refused?(pipeline)
  end

  def test_set_field_and_unset_field_with_computed_name_are_refused
    protect_secret!
    [
      { "$setField" => { "field" => "$selector", "input" => { "a" => 1 }, "value" => 1 } },
      { "$unsetField" => { "field" => { "$concat" => ["a", "b"] }, "input" => { "a" => 1 } } },
    ].each do |expr|
      assert refused?([{ "$project" => { "x" => expr } }]), "expected refusal for #{expr.inspect}"
    end
  end

  def test_plain_and_literal_unprotected_names_are_allowed
    protect_secret!
    [
      { "$getField" => "name" },
      { "$getField" => { "field" => "name" } },
      { "$getField" => { "field" => { "$literal" => "name" } } },
      { "$getField" => { "field" => { "$literal" => "$price" }, "input" => "$meta" } },
      { "$setField" => { "field" => "a", "input" => { "a" => 1 }, "value" => 2 } },
      { "$unsetField" => { "field" => "a", "input" => { "a" => 1 } } },
    ].each do |expr|
      refute refused?([{ "$project" => { "x" => expr } }]), "expected #{expr.inspect} to be allowed"
    end
  end

  def test_computed_name_allowed_for_master_and_classes_without_protected_fields
    Parse::CLPScope.__cache_put("FRPlain", clp: { "find" => { "*" => true } })
    pipeline = [{ "$project" => { "x" => { "$getField" => "$selector" } } }]
    refute refused?(pipeline, "FRPlain")
    protect_secret!
    run_aggregate("FRItem", pipeline, master)
  end

  def test_computed_name_in_join_sub_pipeline_is_refused_for_joined_class
    Parse::CLPScope.__cache_put("FRItem", clp: { "find" => { "*" => true } })
    protect_secret!("FRRef")
    lookup = { "$lookup" => {
      "from" => "FRRef",
      "pipeline" => [{ "$project" => { "x" => { "$getField" => "$selector" } } }],
      "as" => "j",
    } }
    assert refused?([lookup])
  end
end
