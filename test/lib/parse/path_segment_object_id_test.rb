# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# NEW-10: Parse::API::PathSegment.object_id! validates an objectId before it is
# interpolated raw into a REST path. The _User endpoints (fetch/update/delete)
# previously interpolated `id` without validation, so a hostile/compromised
# Parse Server returning a crafted objectId could traverse to a different
# endpoint on the next call with whatever credentials it was authorized to send.
class PathSegmentObjectIdTest < Minitest::Test
  PS = Parse::API::PathSegment

  def test_accepts_valid_object_ids
    %w[abc123 Ab0Z aaaaaaaaaa 0123456789 A].each do |id|
      assert_equal id, PS.object_id!(id), "#{id.inspect} should be accepted"
    end
    # Up to 40 chars.
    long = "a" * 40
    assert_equal long, PS.object_id!(long)
  end

  def test_rejects_path_traversal_and_query_injection
    [
      "../classes/_User",
      "../classes/_User?where=%7B%7D",
      "abc/def",
      "abc?where=1",
      "abc&x=1",
      "abc=1",
      "abc.def",
      "..",
      ".",
      "a b",
      "abc\n",
      "a" * 41, # over the length cap
    ].each do |id|
      assert_raises(ArgumentError, "#{id.inspect} must be rejected") { PS.object_id!(id) }
    end
  end

  def test_rejects_empty
    assert_raises(ArgumentError) { PS.object_id!("") }
    assert_raises(ArgumentError) { PS.object_id!(nil) }
  end

  def test_user_endpoints_reject_hostile_object_id_before_request
    # The validation must fire before any network call. We use a client whose
    # request path would raise loudly if reached; object_id! should raise first.
    client = Parse::Client.new(
      server_url: "http://localhost:1/parse",
      application_id: "app", api_key: "rest",
    )
    %i[fetch_user delete_user].each do |m|
      assert_raises(ArgumentError, "#{m} must reject a traversal objectId") do
        client.public_send(m, "../classes/_User?where=%7B%7D")
      end
    end
    assert_raises(ArgumentError, "update_user must reject a traversal objectId") do
      client.update_user("../classes/_User", { foo: 1 })
    end
  end
end
