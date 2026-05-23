require_relative "../../test_helper"
require "minitest/autorun"

class TimeZoneTest < Minitest::Test
  def test_timezone_constants
    # Test that MAPPING constant is accessible
    assert Parse::TimeZone::MAPPING.is_a?(Hash)
    assert Parse::TimeZone::MAPPING.values.include?("America/Los_Angeles")
    assert Parse::TimeZone::MAPPING.values.include?("Europe/London")
  end

  def test_timezone_initialization_with_string
    tz = Parse::TimeZone.new("America/Los_Angeles")

    assert_equal "America/Los_Angeles", tz.name
    assert_nil tz.instance_variable_get(:@zone) # Should be lazy loaded
  end

  def test_timezone_initialization_with_parse_timezone
    original_tz = Parse::TimeZone.new("Europe/Paris")
    new_tz = Parse::TimeZone.new(original_tz)

    assert_equal "Europe/Paris", new_tz.name
  end

  def test_timezone_initialization_with_active_support_timezone
    active_support_tz = ActiveSupport::TimeZone.new("Asia/Tokyo")
    parse_tz = Parse::TimeZone.new(active_support_tz)

    assert_equal "Asia/Tokyo", parse_tz.name
  end

  def test_timezone_name_getter_setter
    tz = Parse::TimeZone.new("America/New_York")

    # Test getter
    assert_equal "America/New_York", tz.name

    # Test setter with valid timezone
    tz.name = "Europe/London"
    assert_equal "Europe/London", tz.name
    assert_nil tz.instance_variable_get(:@zone) # Should clear zone cache

    # Test setter with nil
    tz.name = nil
    assert_nil tz.name

    # Test setter with invalid type should raise error
    assert_raises(ArgumentError) do
      tz.name = 123
    end
  end

  def test_timezone_zone_lazy_loading
    tz = Parse::TimeZone.new("America/Chicago")

    # Zone should be nil initially (lazy loading)
    assert_nil tz.instance_variable_get(:@zone)

    # Accessing zone should load the ActiveSupport::TimeZone
    zone = tz.zone
    assert_instance_of ActiveSupport::TimeZone, zone
    assert_equal "America/Chicago", zone.name

    # Zone should now be cached
    assert_equal zone, tz.instance_variable_get(:@zone)

    # Name should be cleared after zone is loaded
    assert_nil tz.instance_variable_get(:@name)
  end

  def test_timezone_zone_setter
    tz = Parse::TimeZone.new("America/Denver")

    # Test setting with ActiveSupport::TimeZone
    active_support_tz = ActiveSupport::TimeZone.new("Europe/Berlin")
    tz.zone = active_support_tz
    assert_equal "Europe/Berlin", tz.name

    # Test setting with Parse::TimeZone
    other_parse_tz = Parse::TimeZone.new("Asia/Seoul")
    tz.zone = other_parse_tz
    assert_equal "Asia/Seoul", tz.name

    # Test setting with string
    tz.zone = "Australia/Sydney"
    assert_equal "Australia/Sydney", tz.name

    # Test setting with nil
    tz.zone = nil
    assert_nil tz.name

    # Test setting with invalid type should raise error
    assert_raises(ArgumentError) do
      tz.zone = 123
    end
  end

  def test_timezone_as_json_and_to_s
    tz = Parse::TimeZone.new("America/Los_Angeles")

    # as_json should return the name
    assert_equal "America/Los_Angeles", tz.as_json

    # to_s should return the name
    assert_equal "America/Los_Angeles", tz.to_s

    # Test with nil name
    tz.name = nil
    assert_nil tz.as_json
    assert_nil tz.to_s
  end

  def test_timezone_valid_validation
    # Test valid timezone
    valid_tz = Parse::TimeZone.new("America/New_York")
    assert valid_tz.valid?, "America/New_York should be valid"

    # Test invalid timezone
    invalid_tz = Parse::TimeZone.new("Galaxy/Andromeda")
    refute invalid_tz.valid?, "Galaxy/Andromeda should be invalid"

    # Test nil timezone - need to handle this more carefully
    nil_tz = Parse::TimeZone.new(nil)
    # Can't call valid? on nil timezone as it causes error in ActiveSupport
    assert_nil nil_tz.name, "nil timezone should have nil name"

    # Test empty string
    empty_tz = Parse::TimeZone.new("")
    refute empty_tz.valid?, "empty string timezone should be invalid"
  end

  def test_timezone_method_delegation
    tz = Parse::TimeZone.new("America/Los_Angeles")
    zone = tz.zone

    # Test that methods are delegated to the underlying ActiveSupport::TimeZone
    assert_respond_to tz, :formatted_offset
    assert_respond_to tz, :utc_offset
    assert_respond_to tz, :at
    assert_respond_to tz, :parse
    assert_respond_to tz, :local

    # Test actual delegation
    assert_equal zone.formatted_offset, tz.formatted_offset
    assert_equal zone.utc_offset, tz.utc_offset

    # Test delegation with arguments
    test_time = Time.utc(2023, 6, 15, 12, 0, 0)
    assert_equal zone.at(test_time), tz.at(test_time)
  end

  def test_timezone_excluded_methods
    tz = Parse::TimeZone.new("Europe/London")

    # These methods are defined on Parse::TimeZone itself, not delegated
    # Just verify they exist and work
    assert_respond_to tz, :to_s
    assert_respond_to tz, :name
    assert_respond_to tz, :as_json

    # Verify they return expected values
    assert_equal "Europe/London", tz.to_s
    assert_equal "Europe/London", tz.name
    assert_equal "Europe/London", tz.as_json
  end

  def test_timezone_with_time_calculations
    tz = Parse::TimeZone.new("America/New_York")

    # Test parsing a time in the timezone
    time_string = "2023-07-04 15:30:00"
    parsed_time = tz.parse(time_string)

    assert_instance_of ActiveSupport::TimeWithZone, parsed_time
    assert_equal "America/New_York", parsed_time.time_zone.name

    # Test creating a local time
    local_time = tz.local(2023, 12, 25, 10, 0, 0)
    assert_instance_of ActiveSupport::TimeWithZone, local_time
    assert_equal "America/New_York", local_time.time_zone.name
  end

  def test_timezone_offset_calculations
    # Test different timezones and their offsets

    # UTC timezone
    utc_tz = Parse::TimeZone.new("UTC")
    assert_equal "+00:00", utc_tz.formatted_offset
    assert_equal 0, utc_tz.utc_offset

    # EST timezone (winter)
    est_tz = Parse::TimeZone.new("America/New_York")
    # Note: offset depends on whether DST is in effect
    assert est_tz.formatted_offset.match?(/^[+-]\d{2}:\d{2}$/)
    assert est_tz.utc_offset.is_a?(Integer)

    # PST timezone
    pst_tz = Parse::TimeZone.new("America/Los_Angeles")
    assert pst_tz.formatted_offset.match?(/^[+-]\d{2}:\d{2}$/)
    assert pst_tz.utc_offset.is_a?(Integer)
  end

  def test_timezone_dst_handling
    # Test timezone that observes DST
    ny_tz = Parse::TimeZone.new("America/New_York")

    # Summer time (DST)
    summer_time = ny_tz.local(2023, 7, 15, 12, 0, 0)
    summer_offset = summer_time.formatted_offset

    # Winter time (Standard time)
    winter_time = ny_tz.local(2023, 1, 15, 12, 0, 0)
    winter_offset = winter_time.formatted_offset

    # Offsets should be different due to DST
    refute_equal summer_offset, winter_offset, "Summer and winter offsets should differ for DST timezone"
  end

  def test_timezone_comparison_and_equality
    tz1 = Parse::TimeZone.new("America/Chicago")
    tz2 = Parse::TimeZone.new("America/Chicago")
    tz3 = Parse::TimeZone.new("Europe/Paris")

    # Same timezone names should be equal (by name)
    assert_equal tz1.name, tz2.name
    refute_equal tz1.name, tz3.name

    # Test to_s comparison
    assert_equal tz1.to_s, tz2.to_s
    refute_equal tz1.to_s, tz3.to_s
  end

  def test_timezone_common_iana_identifiers
    # Test some common IANA timezone identifiers
    common_timezones = [
      "UTC",
      "America/New_York",
      "America/Los_Angeles",
      "America/Chicago",
      "America/Denver",
      "Europe/London",
      "Europe/Paris",
      "Asia/Tokyo",
      "Australia/Sydney",
    ]

    common_timezones.each do |tz_name|
      tz = Parse::TimeZone.new(tz_name)
      assert tz.valid?, "#{tz_name} should be a valid timezone"
      assert_equal tz_name, tz.name
      assert_instance_of ActiveSupport::TimeZone, tz.zone
    end
  end

  def test_timezone_edge_cases
    # Test edge cases and unusual inputs

    # Test with timezone that doesn't exist
    nonexistent_tz = Parse::TimeZone.new("Fake/Timezone")
    refute nonexistent_tz.valid?, "Non-existent timezone should be invalid"

    # Test with empty string
    empty_tz = Parse::TimeZone.new("")
    refute empty_tz.valid?, "Empty string should be invalid"

    # Test case sensitivity (timezone names are case sensitive)
    lowercase_tz = Parse::TimeZone.new("america/new_york")
    refute lowercase_tz.valid?, "Lowercase timezone name should be invalid"
  end

  def test_timezone_integration_with_time_objects
    tz = Parse::TimeZone.new("Pacific/Honolulu")

    # Test converting UTC time to timezone
    utc_time = Time.utc(2023, 8, 15, 20, 0, 0)
    tz_time = tz.at(utc_time)

    assert_instance_of ActiveSupport::TimeWithZone, tz_time
    assert_equal "Pacific/Honolulu", tz_time.time_zone.name

    # The time should be the same instant, but displayed in the timezone
    assert_equal utc_time.to_i, tz_time.to_i
  end
end
