# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# A partial fetch that leaves out the ACL must never let a save replace the
# record's real ACL: saving other fields sends no ACL, and reading `acl`
# fetches the stored one instead of returning nil.
class PartialFetchAclTest < Minitest::Test
  class PartialAclPost < Parse::Object
    parse_class "PartialAclPost"
    property :title
    property :body
  end

  ROW = { "objectId" => "p1", "createdAt" => "2026-01-01T00:00:00.000Z",
          "updatedAt" => "2026-01-01T00:00:00.000Z" }.freeze

  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1/parse", application_id: "a", api_key: "k")
    end
    @calls = []
  end

  def response(hash)
    Parse::Response.new(hash)
  end

  def partial_post
    found = response({ "results" => [ROW.merge("title" => "t")] })
    Parse.client.stub(:find_objects, ->(*_a, **_k) { found }) do
      PartialAclPost.query.keys(:title).first
    end
  end

  def test_saving_other_fields_sends_no_acl
    post = partial_post
    post.title = "edited"
    sent = nil
    updated = response({ "updatedAt" => "2026-01-02T00:00:00.000Z" })
    post.client.stub(:fetch_object, ->(*_a, **_k) { flunk "save must not fetch" }) do
      post.client.stub(:update_object, ->(_c, _id, body, **_k) { sent = body; updated }) do
        assert post.save
      end
    end
    refute sent.key?("ACL") || sent.key?(:ACL), sent.inspect
  end

  def test_reading_acl_fetches_the_stored_one
    post = partial_post
    full = response(ROW.merge("title" => "t", "body" => "b", "ACL" => { "*" => { "read" => true } }))
    fetches = 0
    post.client.stub(:fetch_object, ->(*_a, **_k) { fetches += 1; full }) do
      acl = post.acl
      refute_nil acl, "the ACL left out of a partial fetch is fetched, not read as nil"
      assert_equal({ "*" => { "read" => true } }, acl.as_json)
    end
    assert_equal 1, fetches
  end

  def test_a_pointer_does_not_fetch_for_its_acl
    ptr = PartialAclPost.new("p1")
    post_fetches = 0
    ptr.client.stub(:fetch_object, ->(*_a, **_k) { post_fetches += 1; response(ROW) }) do
      ptr.acl
    end
    assert_equal 0, post_fetches
  end
end
