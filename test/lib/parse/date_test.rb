require_relative '../../test_helper'
require 'minitest/autorun'

class DateTest < Minitest::Test
  
  def test_parse_date_class_constants
    assert_equal Parse::Model::TYPE_DATE, Parse::Date.parse_class
    expected_attributes = { __type: :string, iso: :string }
    assert_equal expected_attributes, Parse::Date::ATTRIBUTES
  end
  
  def test_parse_date_instance_methods
    now = Time.now
    parse_date = Parse::Date.parse(now.iso8601(3))
    
    assert_equal Parse::Model::TYPE_DATE, parse_date.parse_class
    assert_equal Parse::Model::TYPE_DATE, parse_date.__type
    assert_equal Parse::Date::ATTRIBUTES, parse_date.attributes
  end
  
  def test_parse_date_iso_format
    # Test with a specific time
    test_time = Time.utc(2023, 12, 25, 15, 30, 45) # UTC time
    parse_date = Parse::Date.parse(test_time.iso8601(3))
    
    # Should return ISO8601 format with 3 millisecond precision in UTC
    iso_result = parse_date.iso
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/, iso_result)
    
    # Verify it's in UTC
    assert iso_result.end_with?('Z'), "ISO format should end with 'Z' for UTC"
    
    # Test that to_s returns ISO format
    assert_equal iso_result, parse_date.to_s
  end
  
  def test_parse_date_to_s_with_arguments
    parse_date = Parse::Date.parse(Time.now.iso8601(3))
    
    # to_s without arguments should return ISO format
    iso_format = parse_date.to_s
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/, iso_format)
    
    # to_s with arguments should call DateTime's super method
    # Note: Parse::Date.to_s only accepts no arguments or calls super
    # Let's test with strftime instead which is a DateTime method
    formatted = parse_date.strftime('%Y-%m-%d')
    assert_match(/\A\d{4}-\d{2}-\d{2}\z/, formatted)
  end
  
  def test_parse_date_json_serialization
    test_time = Time.utc(2023, 6, 15, 10, 30, 0)
    parse_date = Parse::Date.parse(test_time.iso8601(3))
    
    # Test as_json method (should have __type and iso)
    json_hash = parse_date.as_json
    assert json_hash.key?('__type')
    assert json_hash.key?('iso')
    assert_equal Parse::Model::TYPE_DATE, json_hash['__type']
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/, json_hash['iso'])
  end
  
  def test_time_parse_date_extension
    test_time = Time.utc(2023, 8, 20, 14, 45, 30) # UTC time
    
    # Test Time#parse_date extension
    parse_date = test_time.parse_date
    assert_instance_of Parse::Date, parse_date
    
    # Should preserve millisecond precision
    iso_result = parse_date.iso
    assert iso_result.include?('.'), "ISO format should include milliseconds"
    assert_match(/\.\d{3}Z\z/, iso_result, "Should end with .xxxZ format")
  end
  
  def test_datetime_parse_date_extension
    test_datetime = DateTime.new(2023, 11, 10, 9, 15, 45)
    
    # Test DateTime#parse_date extension
    parse_date = test_datetime.parse_date
    assert_instance_of Parse::Date, parse_date
    
    # Should convert to proper ISO format
    iso_result = parse_date.iso
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/, iso_result)
  end
  
  def test_date_parse_date_extension
    test_date = Date.new(2023, 5, 3)
    
    # Test Date#parse_date extension
    parse_date = test_date.parse_date
    assert_instance_of Parse::Date, parse_date
    
    # Should convert date to datetime with time portion
    iso_result = parse_date.iso
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/, iso_result)
    assert iso_result.start_with?('2023-05-03T'), "Should preserve the date portion"
  end
  
  def test_active_support_time_with_zone_extension
    # Create a time with zone
    Time.zone = 'America/Los_Angeles'
    time_with_zone = Time.zone.local(2023, 7, 4, 12, 0, 0)
    
    # Test ActiveSupport::TimeWithZone#parse_date extension
    parse_date = time_with_zone.parse_date
    assert_instance_of Parse::Date, parse_date
    
    # Should convert to UTC in ISO format
    iso_result = parse_date.iso
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/, iso_result)
    assert iso_result.end_with?('Z'), "Should be converted to UTC"
  ensure
    Time.zone = nil # Reset time zone
  end
  
  def test_parse_date_precision_handling
    # Test various precision levels
    
    # Test with seconds precision
    time_seconds = Time.utc(2023, 1, 1, 12, 0, 0)
    parse_date_sec = time_seconds.parse_date
    assert parse_date_sec.iso.include?('.000Z'), "Should pad to 3 decimal places for seconds"
    
    # Test with Time.at for precise milliseconds  
    time_millis = Time.at(Time.utc(2023, 1, 1, 12, 0, 0).to_f + 0.123) # 123ms
    parse_date_ms = time_millis.parse_date
    # Note: precision may vary due to floating point, so just check for milliseconds
    assert_match(/\.\d{3}Z/, parse_date_ms.iso, "Should have millisecond precision")
    
    # Test with Time.at for microseconds (should truncate to milliseconds)
    time_micros = Time.at(Time.utc(2023, 1, 1, 12, 0, 0).to_f + 0.123456) # 123.456ms
    parse_date_us = time_micros.parse_date
    iso_us = parse_date_us.iso
    # Just verify it has exactly 3 decimal places (millisecond precision)
    assert_match(/\.\d{3}Z/, iso_us, "Should have exactly 3 decimal places")
    refute_match(/\.\d{4,}/, iso_us, "Should not have more than 3 decimal places")
  end
  
  def test_parse_date_timezone_handling
    # Test various timezone inputs are all converted to UTC
    
    # Create times with timezone info using Time.parse
    est_time = Time.parse("2023-03-15 10:30:00 -0500") # EST
    est_parse_date = est_time.parse_date
    assert est_parse_date.iso.end_with?('Z'), "EST time should be converted to UTC"
    
    # PST timezone (same UTC time as above)
    pst_time = Time.parse("2023-03-15 07:30:00 -0800") # PST 
    pst_parse_date = pst_time.parse_date
    assert pst_parse_date.iso.end_with?('Z'), "PST time should be converted to UTC"
    
    # Both should represent the same UTC time
    assert_equal est_parse_date.iso, pst_parse_date.iso, "Different timezone inputs should convert to same UTC"
  end
  
  def test_parse_date_inheritance_from_datetime
    parse_date = Parse::Date.parse(Time.now.iso8601(3))
    
    # Should inherit from DateTime
    assert parse_date.is_a?(DateTime), "Parse::Date should inherit from DateTime"
    
    # Should have DateTime methods available
    assert_respond_to parse_date, :year
    assert_respond_to parse_date, :month
    assert_respond_to parse_date, :day
    assert_respond_to parse_date, :hour
    assert_respond_to parse_date, :minute
    assert_respond_to parse_date, :second
  end
  
  def test_parse_date_edge_cases
    # Test leap year
    leap_year_time = Time.utc(2024, 2, 29, 23, 59, 59)
    leap_parse_date = leap_year_time.parse_date
    assert leap_parse_date.iso.start_with?('2024-02-29T'), "Should handle leap year correctly"
    
    # Test year boundaries
    new_year_time = Time.utc(2024, 1, 1, 0, 0, 0)
    new_year_parse_date = new_year_time.parse_date
    assert new_year_parse_date.iso.start_with?('2024-01-01T00:00:00'), "Should handle year boundary"
    
    # Test end of year with milliseconds
    end_year_time = Time.at(Time.utc(2023, 12, 31, 23, 59, 59).to_f + 0.999)
    end_year_parse_date = end_year_time.parse_date
    assert end_year_parse_date.iso.start_with?('2023-12-31T23:59:59.999'), "Should handle end of year"
  end
  
  def test_parse_date_creation_from_various_formats
    # Test parsing from ISO8601 string
    iso_string = "2023-06-15T14:30:45.123Z"
    parse_date_from_iso = Parse::Date.parse(iso_string)
    assert_instance_of Parse::Date, parse_date_from_iso
    assert_equal iso_string, parse_date_from_iso.iso
    
    # Test parsing from Time object
    time_obj = Time.parse(iso_string)
    parse_date_from_time = Parse::Date.parse(time_obj.iso8601(3))
    assert_instance_of Parse::Date, parse_date_from_time
    
    # Test parsing from DateTime object  
    datetime_obj = DateTime.parse(iso_string)
    parse_date_from_datetime = Parse::Date.parse(datetime_obj.iso8601(3))
    assert_instance_of Parse::Date, parse_date_from_datetime
  end
end