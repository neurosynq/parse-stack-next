# encoding: UTF-8
# frozen_string_literal: true

require_relative '../../test_helper'
require 'minitest/autorun'

class NPlusOneDetectorTest < Minitest::Test
  def setup
    # Reset state before each test
    Parse.warn_on_n_plus_one = false
    Parse.reset_n_plus_one_tracking!
    Parse.clear_n_plus_one_callbacks!
  end

  def teardown
    # Clean up after each test
    Parse.warn_on_n_plus_one = false
    Parse.reset_n_plus_one_tracking!
    Parse.clear_n_plus_one_callbacks!
  end

  def test_detector_disabled_by_default
    refute Parse.warn_on_n_plus_one, "N+1 detection should be disabled by default"
    refute Parse::NPlusOneDetector.enabled?, "Detector should be disabled"
  end

  def test_detector_can_be_enabled
    Parse.warn_on_n_plus_one = true
    assert Parse.warn_on_n_plus_one, "N+1 detection should be enabled"
    assert Parse::NPlusOneDetector.enabled?, "Detector should be enabled"
  end

  def test_tracking_is_thread_local
    Parse.warn_on_n_plus_one = true

    # Track some events in main thread
    3.times do |i|
      Parse::NPlusOneDetector.track_autofetch(
        source_class: "Song",
        association: :artist,
        target_class: "Artist",
        object_id: "main_#{i}"
      )
    end

    summary_main = Parse.n_plus_one_summary

    # Track different events in a different thread
    thread = Thread.new do
      Parse.warn_on_n_plus_one = true
      5.times do |i|
        Parse::NPlusOneDetector.track_autofetch(
          source_class: "Book",
          association: :author,
          target_class: "Author",
          object_id: "thread_#{i}"
        )
      end
      Parse.n_plus_one_summary
    end

    summary_thread = thread.value

    # Each thread should have independent tracking
    main_associations = summary_main[:associations].map { |a| a[:pattern] }
    thread_associations = summary_thread[:associations].map { |a| a[:pattern] }

    assert main_associations.include?("Song.artist"), "Main thread should track Song.artist"
    assert thread_associations.include?("Book.author"), "Thread should track Book.author"
  end

  def test_no_tracking_when_disabled
    # Don't enable detection
    refute Parse.warn_on_n_plus_one

    5.times do |i|
      Parse::NPlusOneDetector.track_autofetch(
        source_class: "Song",
        association: :artist,
        target_class: "Artist",
        object_id: "id_#{i}"
      )
    end

    summary = Parse.n_plus_one_summary
    assert_equal 0, summary[:patterns_detected], "Should not track when disabled"
  end

  def test_detection_threshold
    Parse.warn_on_n_plus_one = true

    # Track just under threshold (3 is the default threshold)
    2.times do |i|
      Parse::NPlusOneDetector.track_autofetch(
        source_class: "Song",
        association: :artist,
        target_class: "Artist",
        object_id: "id_#{i}"
      )
    end

    summary = Parse.n_plus_one_summary
    assert_equal 0, summary[:patterns_detected], "Should not warn under threshold"

    # Add one more to trigger threshold
    Parse::NPlusOneDetector.track_autofetch(
      source_class: "Song",
      association: :artist,
      target_class: "Artist",
      object_id: "id_3"
    )

    summary = Parse.n_plus_one_summary
    assert_equal 1, summary[:patterns_detected], "Should warn after threshold"
  end

  def test_callback_registration
    callbacks_received = []

    Parse.on_n_plus_one do |source, assoc, target, count, location|
      callbacks_received << {
        source: source,
        association: assoc,
        target: target,
        count: count
      }
    end

    assert_equal 1, Parse::NPlusOneDetector.callbacks.size, "Should have one callback"

    # Trigger an N+1 warning
    Parse.warn_on_n_plus_one = true
    4.times do |i|
      Parse::NPlusOneDetector.track_autofetch(
        source_class: "Song",
        association: :artist,
        target_class: "Artist",
        object_id: "id_#{i}"
      )
    end

    assert_equal 1, callbacks_received.size, "Callback should have been invoked"
    assert_equal "Song", callbacks_received.first[:source]
    assert_equal :artist, callbacks_received.first[:association]
    assert_equal "Artist", callbacks_received.first[:target]
  end

  def test_clear_callbacks
    Parse.on_n_plus_one { |*args| }
    Parse.on_n_plus_one { |*args| }

    assert_equal 2, Parse::NPlusOneDetector.callbacks.size
    Parse.clear_n_plus_one_callbacks!
    assert_equal 0, Parse::NPlusOneDetector.callbacks.size
  end

  def test_reset_tracking
    Parse.warn_on_n_plus_one = true

    5.times do |i|
      Parse::NPlusOneDetector.track_autofetch(
        source_class: "Song",
        association: :artist,
        target_class: "Artist",
        object_id: "id_#{i}"
      )
    end

    summary = Parse.n_plus_one_summary
    assert summary[:patterns_detected] > 0, "Should have patterns before reset"

    Parse.reset_n_plus_one_tracking!

    summary = Parse.n_plus_one_summary
    assert_equal 0, summary[:patterns_detected], "Should have no patterns after reset"
  end

  def test_multiple_associations_tracked_separately
    Parse.warn_on_n_plus_one = true

    # Track Song.artist
    4.times do |i|
      Parse::NPlusOneDetector.track_autofetch(
        source_class: "Song",
        association: :artist,
        target_class: "Artist",
        object_id: "artist_#{i}"
      )
    end

    # Track Song.album
    4.times do |i|
      Parse::NPlusOneDetector.track_autofetch(
        source_class: "Song",
        association: :album,
        target_class: "Album",
        object_id: "album_#{i}"
      )
    end

    summary = Parse.n_plus_one_summary
    assert_equal 2, summary[:patterns_detected], "Should detect both patterns"

    patterns = summary[:associations].map { |a| a[:pattern] }
    assert patterns.include?("Song.artist"), "Should include Song.artist"
    assert patterns.include?("Song.album"), "Should include Song.album"
  end

  def test_summary_structure
    Parse.warn_on_n_plus_one = true

    4.times do |i|
      Parse::NPlusOneDetector.track_autofetch(
        source_class: "Song",
        association: :artist,
        target_class: "Artist",
        object_id: "id_#{i}"
      )
    end

    summary = Parse.n_plus_one_summary

    assert summary.key?(:patterns_detected), "Summary should have patterns_detected"
    assert summary.key?(:associations), "Summary should have associations"
    assert summary[:associations].is_a?(Array), "associations should be an array"

    assoc = summary[:associations].first
    assert assoc.key?(:pattern), "Association should have pattern"
    assert assoc.key?(:fetches), "Association should have fetches"
    assert assoc.key?(:warned), "Association should have warned"
  end

  # ============================================
  # N+1 Mode Tests
  # ============================================

  def test_default_mode_is_ignore
    Parse.reset_n_plus_one_tracking!
    Parse::NPlusOneDetector.mode = :ignore  # Reset to default
    assert_equal :ignore, Parse.n_plus_one_mode, "Default mode should be :ignore"
  end

  def test_mode_can_be_set_to_warn
    Parse.n_plus_one_mode = :warn
    assert_equal :warn, Parse.n_plus_one_mode, "Mode should be :warn"
    assert Parse.warn_on_n_plus_one, "Detection should be enabled in warn mode"
  end

  def test_mode_can_be_set_to_raise
    Parse.n_plus_one_mode = :raise
    assert_equal :raise, Parse.n_plus_one_mode, "Mode should be :raise"
    assert Parse.warn_on_n_plus_one, "Detection should be enabled in raise mode"
  end

  def test_mode_can_be_set_to_ignore
    Parse.n_plus_one_mode = :warn  # First enable
    Parse.n_plus_one_mode = :ignore
    assert_equal :ignore, Parse.n_plus_one_mode, "Mode should be :ignore"
    refute Parse.warn_on_n_plus_one, "Detection should be disabled in ignore mode"
  end

  def test_invalid_mode_raises_error
    assert_raises(ArgumentError) do
      Parse.n_plus_one_mode = :invalid
    end
  end

  def test_mode_accepts_strings
    Parse.n_plus_one_mode = "warn"
    assert_equal :warn, Parse.n_plus_one_mode, "Mode should accept string 'warn'"

    Parse.n_plus_one_mode = "raise"
    assert_equal :raise, Parse.n_plus_one_mode, "Mode should accept string 'raise'"
  end

  def test_raise_mode_raises_exception
    Parse.n_plus_one_mode = :raise

    # Track enough to trigger threshold
    error = assert_raises(Parse::NPlusOneQueryError) do
      4.times do |i|
        Parse::NPlusOneDetector.track_autofetch(
          source_class: "Song",
          association: :artist,
          target_class: "Artist",
          object_id: "id_#{i}"
        )
      end
    end

    assert_equal "Song", error.source_class
    assert_equal :artist, error.association
    assert_equal "Artist", error.target_class
    assert error.count >= 3, "Count should be at least threshold"
    assert_match(/N\+1 query detected/, error.message)
    assert_match(/includes\(:artist\)/, error.message)
  end

  def test_warn_mode_does_not_raise
    Parse.n_plus_one_mode = :warn

    # Should not raise, just warn
    4.times do |i|
      Parse::NPlusOneDetector.track_autofetch(
        source_class: "Song",
        association: :artist,
        target_class: "Artist",
        object_id: "id_#{i}"
      )
    end

    # If we got here without exception, test passes
    assert true
  end

  def test_ignore_mode_does_not_track
    Parse.n_plus_one_mode = :ignore

    5.times do |i|
      Parse::NPlusOneDetector.track_autofetch(
        source_class: "Song",
        association: :artist,
        target_class: "Artist",
        object_id: "id_#{i}"
      )
    end

    summary = Parse.n_plus_one_summary
    assert_equal 0, summary[:patterns_detected], "Should not track in ignore mode"
  end

  def test_callbacks_run_in_raise_mode
    callbacks_received = []

    Parse.on_n_plus_one do |source, assoc, target, count, location|
      callbacks_received << { source: source, association: assoc }
    end

    Parse.n_plus_one_mode = :raise

    # Callbacks should still be invoked even though exception is raised
    assert_raises(Parse::NPlusOneQueryError) do
      4.times do |i|
        Parse::NPlusOneDetector.track_autofetch(
          source_class: "Song",
          association: :artist,
          target_class: "Artist",
          object_id: "id_#{i}"
        )
      end
    end

    assert_equal 1, callbacks_received.size, "Callback should be invoked in raise mode"
  end

  def test_warn_on_n_plus_one_true_sets_warn_mode
    Parse.n_plus_one_mode = :ignore
    Parse.warn_on_n_plus_one = true
    assert_equal :warn, Parse.n_plus_one_mode, "Setting warn_on_n_plus_one=true should set :warn mode"
  end

  def test_warn_on_n_plus_one_false_sets_ignore_mode
    Parse.n_plus_one_mode = :raise
    Parse.warn_on_n_plus_one = false
    assert_equal :ignore, Parse.n_plus_one_mode, "Setting warn_on_n_plus_one=false should set :ignore mode"
  end

  # ============================================
  # Configurable Thresholds Tests
  # ============================================

  def test_default_thresholds
    assert_equal 2.0, Parse::NPlusOneDetector::DEFAULT_DETECTION_WINDOW
    assert_equal 3, Parse::NPlusOneDetector::DEFAULT_FETCH_THRESHOLD
    assert_equal 60.0, Parse::NPlusOneDetector::DEFAULT_CLEANUP_INTERVAL
  end

  def test_detection_window_configurable
    original = Parse::NPlusOneDetector.detection_window

    Parse.n_plus_one_detection_window = 5.0
    assert_equal 5.0, Parse.n_plus_one_detection_window

    # Reset
    Parse::NPlusOneDetector.detection_window = original
  end

  def test_fetch_threshold_configurable
    original = Parse::NPlusOneDetector.fetch_threshold

    Parse.n_plus_one_fetch_threshold = 10
    assert_equal 10, Parse.n_plus_one_fetch_threshold

    # Reset
    Parse::NPlusOneDetector.fetch_threshold = original
  end

  def test_configure_block
    original_window = Parse::NPlusOneDetector.detection_window
    original_threshold = Parse::NPlusOneDetector.fetch_threshold
    original_interval = Parse::NPlusOneDetector.cleanup_interval

    Parse.configure_n_plus_one do |config|
      config.detection_window = 10.0
      config.fetch_threshold = 5
      config.cleanup_interval = 120.0
    end

    assert_equal 10.0, Parse::NPlusOneDetector.detection_window
    assert_equal 5, Parse::NPlusOneDetector.fetch_threshold
    assert_equal 120.0, Parse::NPlusOneDetector.cleanup_interval

    # Reset
    Parse::NPlusOneDetector.detection_window = original_window
    Parse::NPlusOneDetector.fetch_threshold = original_threshold
    Parse::NPlusOneDetector.cleanup_interval = original_interval
  end

  def test_custom_threshold_affects_detection
    original = Parse::NPlusOneDetector.fetch_threshold

    # Set a higher threshold
    Parse::NPlusOneDetector.fetch_threshold = 5
    Parse.warn_on_n_plus_one = true

    # Track 4 fetches (under the new threshold of 5)
    4.times do |i|
      Parse::NPlusOneDetector.track_autofetch(
        source_class: "Song",
        association: :artist,
        target_class: "Artist",
        object_id: "id_#{i}"
      )
    end

    summary = Parse.n_plus_one_summary
    assert_equal 0, summary[:patterns_detected], "Should not warn under custom threshold"

    # Add one more to trigger
    Parse::NPlusOneDetector.track_autofetch(
      source_class: "Song",
      association: :artist,
      target_class: "Artist",
      object_id: "id_5"
    )

    summary = Parse.n_plus_one_summary
    assert_equal 1, summary[:patterns_detected], "Should warn after custom threshold"

    # Reset
    Parse::NPlusOneDetector.fetch_threshold = original
  end

  # ============================================
  # Source Registry Tests
  # ============================================

  def test_source_registry_register_and_lookup
    Parse.warn_on_n_plus_one = true

    # Create a mock pointer-like object
    mock_pointer = Object.new

    Parse::NPlusOneDetector.register_source(mock_pointer,
      source_class: "Song",
      association: :artist
    )

    source_info = Parse::NPlusOneDetector.lookup_source(mock_pointer)

    assert_equal "Song", source_info[:source_class]
    assert_equal :artist, source_info[:association]
    assert source_info[:registered_at].is_a?(Float)
  end

  def test_source_registry_returns_nil_for_unregistered
    Parse.warn_on_n_plus_one = true

    unregistered_object = Object.new
    assert_nil Parse::NPlusOneDetector.lookup_source(unregistered_object)
  end

  def test_source_registry_disabled_when_detection_off
    Parse.warn_on_n_plus_one = false

    mock_pointer = Object.new
    Parse::NPlusOneDetector.register_source(mock_pointer,
      source_class: "Song",
      association: :artist
    )

    # Should not register when disabled
    assert_nil Parse::NPlusOneDetector.lookup_source(mock_pointer)
  end

  def test_source_registry_cleared_on_reset
    Parse.warn_on_n_plus_one = true

    mock_pointer = Object.new
    Parse::NPlusOneDetector.register_source(mock_pointer,
      source_class: "Song",
      association: :artist
    )

    # Verify it's registered
    assert Parse::NPlusOneDetector.lookup_source(mock_pointer)

    # Reset
    Parse.reset_n_plus_one_tracking!

    # Should be cleared
    assert_nil Parse::NPlusOneDetector.lookup_source(mock_pointer)
  end

  def test_source_registry_uses_object_id
    Parse.warn_on_n_plus_one = true

    obj1 = Object.new
    obj2 = Object.new

    Parse::NPlusOneDetector.register_source(obj1,
      source_class: "Song",
      association: :artist
    )

    Parse::NPlusOneDetector.register_source(obj2,
      source_class: "Album",
      association: :tracks
    )

    # Each object should have its own entry
    source1 = Parse::NPlusOneDetector.lookup_source(obj1)
    source2 = Parse::NPlusOneDetector.lookup_source(obj2)

    assert_equal "Song", source1[:source_class]
    assert_equal "Album", source2[:source_class]
  end

  def test_lookup_source_returns_nil_for_nil_input
    assert_nil Parse::NPlusOneDetector.lookup_source(nil)
  end
end
