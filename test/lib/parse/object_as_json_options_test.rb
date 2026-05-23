# frozen_string_literal: true

require_relative "../../test_helper"
require "minitest/autorun"

# Test model for as_json options testing
class AsJsonTestSong < Parse::Object
  parse_class "AsJsonTestSong"
  property :title, :string
  property :artist, :string
  property :duration, :integer
  property :genre, :string
  property :play_count, :integer
end

class ObjectAsJsonOptionsTest < Minitest::Test
  def setup
    # Create new object without id to avoid pointer state
    # (objects with id but no timestamps are treated as pointers)
    @song = AsJsonTestSong.new(
      title: "Test Song",
      artist: "Test Artist",
      duration: 180,
      genre: "Rock",
      play_count: 1000,
    )
  end

  # === :except option ===

  def test_except_excludes_single_field
    result = @song.as_json(except: [:duration])

    assert result.key?("title"), "Should include title"
    assert result.key?("artist"), "Should include artist"
    refute result.key?("duration"), "Should exclude duration"
    assert result.key?("genre"), "Should include genre"
  end

  def test_except_excludes_multiple_fields
    result = @song.as_json(except: [:duration, :play_count, :genre])

    assert result.key?("title"), "Should include title"
    assert result.key?("artist"), "Should include artist"
    refute result.key?("duration"), "Should exclude duration"
    refute result.key?("genre"), "Should exclude genre"
    refute result.key?("play_count"), "Should exclude play_count"
  end

  def test_except_with_string_keys
    result = @song.as_json(except: %w[duration genre])

    assert result.key?("title"), "Should include title"
    refute result.key?("duration"), "Should exclude duration"
    refute result.key?("genre"), "Should exclude genre"
  end

  def test_except_preserves_parse_metadata
    result = @song.as_json(except: [:title, :artist])

    # New objects don't have objectId, but should have type info
    assert result.key?("__type"), "Should include __type"
    assert result.key?("className"), "Should include className"
  end

  def test_except_can_exclude_metadata_fields
    result = @song.as_json(except: [:created_at, :updated_at, :acl])

    refute result.key?("created_at"), "Should exclude created_at"
    refute result.key?("updated_at"), "Should exclude updated_at"
    refute result.key?("acl") && result.key?("ACL"), "Should exclude acl"
  end

  # === :exclude_keys option (alias for :except) ===

  def test_exclude_keys_excludes_single_field
    result = @song.as_json(exclude_keys: [:duration])

    assert result.key?("title"), "Should include title"
    assert result.key?("artist"), "Should include artist"
    refute result.key?("duration"), "Should exclude duration"
  end

  def test_exclude_keys_excludes_multiple_fields
    result = @song.as_json(exclude_keys: [:duration, :play_count])

    assert result.key?("title"), "Should include title"
    refute result.key?("duration"), "Should exclude duration"
    refute result.key?("play_count"), "Should exclude play_count"
  end

  def test_exclude_keys_with_string_keys
    result = @song.as_json(exclude_keys: %w[artist genre])

    assert result.key?("title"), "Should include title"
    refute result.key?("artist"), "Should exclude artist"
    refute result.key?("genre"), "Should exclude genre"
  end

  def test_exclude_keys_works_same_as_except
    except_result = @song.as_json(except: [:duration, :genre])
    exclude_keys_result = @song.as_json(exclude_keys: [:duration, :genre])

    assert_equal except_result, exclude_keys_result
  end

  # === :exclude option (alias for :except) ===

  def test_exclude_excludes_single_field
    result = @song.as_json(exclude: [:duration])

    assert result.key?("title"), "Should include title"
    assert result.key?("artist"), "Should include artist"
    refute result.key?("duration"), "Should exclude duration"
  end

  def test_exclude_excludes_multiple_fields
    result = @song.as_json(exclude: [:duration, :play_count])

    assert result.key?("title"), "Should include title"
    refute result.key?("duration"), "Should exclude duration"
    refute result.key?("play_count"), "Should exclude play_count"
  end

  def test_exclude_works_same_as_except
    except_result = @song.as_json(except: [:duration, :genre])
    exclude_result = @song.as_json(exclude: [:duration, :genre])

    assert_equal except_result, exclude_result
  end

  # === :except takes precedence over :exclude_keys and :exclude ===

  def test_except_takes_precedence_over_exclude_keys
    # When both are provided, :except wins
    result = @song.as_json(except: [:duration], exclude_keys: [:title, :artist])

    refute result.key?("duration"), "Should exclude duration (from :except)"
    assert result.key?("title"), "Should include title (exclude_keys ignored)"
    assert result.key?("artist"), "Should include artist (exclude_keys ignored)"
  end

  # === :only option ===

  def test_only_includes_specified_fields
    result = @song.as_json(only: [:title, :artist])

    assert result.key?("title"), "Should include title"
    assert result.key?("artist"), "Should include artist"
    refute result.key?("duration"), "Should not include duration"
    refute result.key?("genre"), "Should not include genre"
  end

  def test_only_always_includes_identification_fields
    result = @song.as_json(only: [:title])

    # Should include specified field
    assert result.key?("title"), "Should include title"

    # Should also include identification fields automatically
    assert result.key?("__type"), "Should include __type for identification"
    assert result.key?("className"), "Should include className for identification"

    # Should NOT include other fields
    refute result.key?("artist"), "Should not include artist"
    refute result.key?("duration"), "Should not include duration"
  end

  def test_only_includes_objectId_when_present
    # Create object with objectId (simulating fetched object)
    song_with_id = AsJsonTestSong.new(
      "objectId" => "abc123",
      "title" => "Test",
      "createdAt" => "2024-01-01T00:00:00.000Z",
      "updatedAt" => "2024-01-01T00:00:00.000Z"
    )

    result = song_with_id.as_json(only: [:title])

    assert result.key?("title"), "Should include title"
    assert result.key?("objectId"), "Should include objectId for identification"
    assert_equal "abc123", result["objectId"]
  end

  # === :strict option (disables auto-including identification fields) ===

  def test_only_with_strict_does_not_include_identification_fields
    result = @song.as_json(only: [:title, :artist], strict: true)

    assert result.key?("title"), "Should include title"
    assert result.key?("artist"), "Should include artist"
    refute result.key?("__type"), "Should NOT include __type with strict: true"
    refute result.key?("className"), "Should NOT include className with strict: true"
    refute result.key?("objectId"), "Should NOT include objectId with strict: true"
  end

  def test_strict_only_includes_exactly_specified_fields
    song_with_id = AsJsonTestSong.new(
      "objectId" => "abc123",
      "title" => "Test",
      "artist" => "Artist",
      "createdAt" => "2024-01-01T00:00:00.000Z",
      "updatedAt" => "2024-01-01T00:00:00.000Z"
    )

    result = song_with_id.as_json(only: [:title], strict: true)

    assert result.key?("title"), "Should include title"
    refute result.key?("objectId"), "Should NOT include objectId with strict"
    refute result.key?("className"), "Should NOT include className with strict"
    refute result.key?("__type"), "Should NOT include __type with strict"
    refute result.key?("artist"), "Should NOT include artist"
  end

  def test_strict_false_is_default_behavior
    result_default = @song.as_json(only: [:title])
    result_explicit = @song.as_json(only: [:title], strict: false)

    assert_equal result_default.keys.sort, result_explicit.keys.sort
  end

  # === Combined :only and :except ===

  def test_only_takes_precedence_over_except
    # ActiveModel behavior: :only takes precedence, :except is ignored when :only is present
    result = @song.as_json(only: [:title, :artist, :duration], except: [:duration])

    assert result.key?("title"), "Should include title"
    assert result.key?("artist"), "Should include artist"
    assert result.key?("duration"), "Duration included because :only takes precedence"
    refute result.key?("genre"), "Should not include genre (not in :only)"
  end

  # === Edge cases ===

  def test_except_with_empty_array
    result = @song.as_json(except: [])

    assert result.key?("title"), "Should include all fields when except is empty"
    assert result.key?("artist")
    assert result.key?("duration")
  end

  def test_exclude_keys_with_empty_array
    result = @song.as_json(exclude_keys: [])

    assert result.key?("title"), "Should include all fields when exclude_keys is empty"
    assert result.key?("artist")
  end

  def test_except_with_nonexistent_field
    # Should not raise error for nonexistent fields
    result = @song.as_json(except: [:nonexistent_field])

    assert result.key?("title"), "Should include existing fields"
  end

  def test_as_json_returns_hash
    result = @song.as_json(except: [:duration])

    assert_instance_of Hash, result
  end
end
