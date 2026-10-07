require_relative "../../test_helper_integration"
require "minitest/autorun"

class QcfArtist < Parse::Object
  parse_class "QcfArtist"
  property :name, :string
end

class QcfSong < Parse::Object
  parse_class "QcfSong"
  property :title, :string
  property :plays, :integer
  belongs_to :artist, as: :qcf_artist
end

# Live checks for the query compilation fixes: a bare objectId on a declared
# pointer matches on REST, and an OR with an unconstrained branch returns
# every row.
class QueryCompileFixesIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def seed
    @artist = QcfArtist.new(name: "A")
    assert @artist.save
    other = QcfArtist.new(name: "B")
    assert other.save
    @mine = QcfSong.new(title: "mine", plays: 1, artist: @artist)
    assert @mine.save
    @theirs = QcfSong.new(title: "theirs", plays: 2, artist: other)
    assert @theirs.save
  end

  def test_bare_object_id_matches_declared_pointer_on_rest
    with_parse_server do
      seed
      assert_equal [@mine.id], QcfSong.query(:artist => @artist.id).results.map(&:id)
      assert_equal [@theirs.id], QcfSong.query(:artist.ne => @artist.id).results.map(&:id)
      assert_equal [@mine.id], QcfSong.query(:artist.in => [@artist.id]).results.map(&:id)
      assert_equal 1, QcfSong.query(:artist => @artist.id).count
      # Direct read agrees with REST.
      if Parse::MongoDB.available?
        assert_equal [@mine.id], QcfSong.query(:artist => @artist.id).results_direct.map(&:id)
      end
    end
  end

  def test_or_with_unconstrained_branch_returns_every_row
    with_parse_server do
      seed
      ids = [@mine.id, @theirs.id].sort
      assert_equal ids, (QcfSong.query(:plays => 1) | QcfSong.query).results.map(&:id).sort
      assert_equal ids, Parse::Query.or(QcfSong.query(:plays => 1), QcfSong.query).results.map(&:id).sort
      assert_equal ids, QcfSong.query(:or => [{ :plays => 1 }, { :plays => 2 }]).results.map(&:id).sort
      assert_equal [@mine.id], QcfSong.query(:title => "mine", :or => [{ :plays => 1 }, { :plays => 2 }]).results.map(&:id)
      assert_equal [], QcfSong.query(:or => []).results
    end
  end

  def test_repeated_order_field_uses_last_direction
    with_parse_server do
      seed
      titles = QcfSong.query.order(:title, :title.desc).results.map(&:title)
      assert_equal %w[theirs mine], titles
    end
  end
end
