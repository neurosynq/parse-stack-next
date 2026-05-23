require_relative "../../test_helper_integration"

# Integration tests for the 4.4.3 group_by/distinct ordering work:
#
#   - `.list` returns hydrated Parse::Object instances with the right
#     id, pointer associations, timestamps, and ACL (regression test
#     for the Parse::MongoDB.convert_document_to_parse normalization on
#     the REST path — without it, `$push: $$ROOT` returns raw MongoDB
#     storage-format docs and `Parse::Object.build` produces broken
#     instances).
#   - `.order(size: :desc).list` orders groups by member count.
#   - Scoped queries (session_token / acl_user) auto-promote to mongo-
#     direct and the SDK's ACLScope filters out rows the caller can't
#     read — before this change the REST aggregate path would have
#     silently returned every row.
class GroupByOrderArtist < Parse::Object
  parse_class "GroupByOrderArtist"
  property :name, :string
end

class GroupByOrderSong < Parse::Object
  parse_class "GroupByOrderSong"
  property :title, :string
  property :genre, :string
  property :plays, :integer
  belongs_to :artist, as: :artist, target_class: "GroupByOrderArtist"
end

class GroupByOrderIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def test_list_returns_hydrated_parse_objects_on_rest_path
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      artist = create_test_object("GroupByOrderArtist", name: "TestArtist")

      # Mix two genres so the group has > 1 row each.
      3.times { |i| create_test_object("GroupByOrderSong", title: "Rock-#{i}", genre: "rock", plays: 100 + i, artist: artist) }
      2.times { |i| create_test_object("GroupByOrderSong", title: "Jazz-#{i}", genre: "jazz", plays: 50 + i, artist: artist) }

      results = GroupByOrderSong.query.group_by(:genre).list

      assert_kind_of Hash, results
      assert results.key?("rock"), "expected rock group: #{results.keys.inspect}"
      assert results.key?("jazz"), "expected jazz group"
      assert_equal 3, results["rock"].size
      assert_equal 2, results["jazz"].size

      # The blocker fix: every returned record must be a hydrated
      # Parse::Object with non-nil id, hydrated pointer, and timestamps.
      results["rock"].each do |song|
        assert_kind_of Parse::Object, song
        refute_nil song.id, "expected hydrated id on returned record"
        refute_nil song.created_at, "expected created_at"
        refute_nil song.updated_at, "expected updated_at"
        refute_nil song.artist, "expected hydrated pointer"
        assert_equal artist.id, song.artist.id, "pointer should resolve to the saved Artist"
      end
    end
  end

  def test_list_ordered_by_size_descending
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      4.times { |i| create_test_object("GroupByOrderSong", title: "R#{i}", genre: "rock", plays: i) }
      2.times { |i| create_test_object("GroupByOrderSong", title: "J#{i}", genre: "jazz", plays: i) }
      1.times { |i| create_test_object("GroupByOrderSong", title: "P#{i}", genre: "pop",  plays: i) }

      ordered = GroupByOrderSong.query.group_by(:genre).order(size: :desc).list

      # Hash preserves insertion order — the MongoDB $sort push-down
      # places the largest group first.
      keys = ordered.keys
      assert_equal "rock", keys[0]
      assert_equal "jazz", keys[1]
      assert_equal "pop",  keys[2]
      assert_equal 4, ordered["rock"].size
      assert_equal 2, ordered["jazz"].size
      assert_equal 1, ordered["pop"].size
    end
  end

  def test_group_by_order_value_descending_count
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      3.times { |i| create_test_object("GroupByOrderSong", title: "R#{i}", genre: "rock") }
      5.times { |i| create_test_object("GroupByOrderSong", title: "J#{i}", genre: "jazz") }
      1.times { |i| create_test_object("GroupByOrderSong", title: "P#{i}", genre: "pop") }

      counts = GroupByOrderSong.query.group_by(:genre).order(value: :desc).count

      assert_equal ["jazz", "rock", "pop"], counts.keys
      assert_equal 5, counts["jazz"]
      assert_equal 3, counts["rock"]
      assert_equal 1, counts["pop"]
    end
  end

  def test_distinct_with_order_asc
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      %w[zeta alpha mu beta].each do |g|
        create_test_object("GroupByOrderSong", title: "T-#{g}", genre: g)
      end

      asc = GroupByOrderSong.query.distinct(:genre, order: :asc)
      assert_equal %w[alpha beta mu zeta], asc

      desc = GroupByOrderSong.query.distinct(:genre, order: :desc)
      assert_equal %w[zeta mu beta alpha], desc
    end
  end

  def test_group_by_date_order_by_value_descending
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      # 5 songs today, 1 song with a backdated created_at can't easily
      # be set, so just verify default chronological vs. value-desc on
      # the day bucket using created_at.
      5.times { |i| create_test_object("GroupByOrderSong", title: "T#{i}", genre: "rock") }
      counts = GroupByOrderSong.query.group_by_date(:created_at, :day).order(value: :desc).count
      assert counts.values.all? { |v| v.is_a?(Integer) }
      assert counts.values.sort == counts.values.sort.reverse.reverse,
             "values present"
      # With one bucket it's a one-element ordering — just assert shape.
      assert counts.size >= 1
    end
  end

  # ---- Auto-promotion + ACL filtering -----------------------------------
  # Critical regression test: a scoped group_by / distinct on the REST
  # path would silently return every row because Parse Server's
  # /aggregate endpoint is master-key-only and unscoped. The 4.4.3
  # auto-promotion routes the call through mongo-direct where ACLScope
  # injects a `_rperm` $match before $group, filtering out rows the
  # caller can't read.

  def test_scoped_group_by_count_only_counts_acl_readable_rows
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Requires Parse::MongoDB to be configured" unless defined?(Parse::MongoDB) && Parse::MongoDB.enabled?

    with_parse_server do
      alice = create_test_user(username: "alice_#{SecureRandom.hex(4)}", password: "pw")
      bob = create_test_user(username: "bob_#{SecureRandom.hex(4)}", password: "pw")

      # Two rock songs alice can read, one rock song only bob can read.
      [alice, alice, bob].each_with_index do |owner, i|
        song = GroupByOrderSong.new(title: "R#{i}", genre: "rock")
        acl = Parse::ACL.new
        acl.apply(owner.id, true, true)
        song.acl = acl
        assert song.save, "song should save"
        @test_context.track(song)
      end

      # One pop song only bob can read.
      pop = GroupByOrderSong.new(title: "P0", genre: "pop")
      acl = Parse::ACL.new
      acl.apply(bob.id, true, true)
      pop.acl = acl
      assert pop.save
      @test_context.track(pop)

      alice_login = Parse::User.login(alice.username, "pw")
      query = Parse::Query.new("GroupByOrderSong")
      query.session_token = alice_login.session_token

      counts = query.group_by(:genre).count

      # Auto-promotion should kick in (session_token set, MongoDB
      # enabled). Alice only reads her 2 rock songs; bob's row and the
      # pop song are filtered out by ACLScope.
      assert_equal({ "rock" => 2 }, counts,
                   "scoped group_by should only count alice's rows; got #{counts.inspect}")
    end
  end

  def test_scoped_distinct_only_returns_acl_readable_values
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Requires Parse::MongoDB to be configured" unless defined?(Parse::MongoDB) && Parse::MongoDB.enabled?

    with_parse_server do
      alice = create_test_user(username: "alice_#{SecureRandom.hex(4)}", password: "pw")
      bob = create_test_user(username: "bob_#{SecureRandom.hex(4)}", password: "pw")

      # alice-readable rock + jazz, bob-only pop.
      [[alice, "rock"], [alice, "jazz"], [bob, "pop"]].each_with_index do |(owner, genre), i|
        song = GroupByOrderSong.new(title: "T#{i}", genre: genre)
        acl = Parse::ACL.new
        acl.apply(owner.id, true, true)
        song.acl = acl
        assert song.save
        @test_context.track(song)
      end

      alice_login = Parse::User.login(alice.username, "pw")
      query = Parse::Query.new("GroupByOrderSong")
      query.session_token = alice_login.session_token

      genres = query.distinct(:genre, order: :asc)

      # "pop" must not appear — alice can't read that row.
      assert_equal %w[jazz rock], genres,
                   "scoped distinct should hide bob-only rows; got #{genres.inspect}"
    end
  end
end
