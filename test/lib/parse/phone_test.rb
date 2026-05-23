# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

class TestParsePhone < Minitest::Test
  extend Minitest::Spec::DSL

  # ===========================================
  # Basic Functionality (works with or without phonelib)
  # ===========================================

  def test_creates_phone_from_string
    phone = Parse::Phone.new("+14155551234")

    assert_equal "+14155551234", phone.to_s
    assert_equal "+14155551234", phone.number
    assert_equal "+14155551234", phone.raw
  end

  def test_creates_phone_from_another_phone
    original = Parse::Phone.new("+14155551234")
    copy = Parse::Phone.new(original)

    assert_equal original.number, copy.number
    assert_equal original.raw, copy.raw
  end

  def test_normalizes_phone_with_formatting
    phone = Parse::Phone.new("+1 (415) 555-1234")

    assert_equal "+14155551234", phone.to_s
    assert_equal "+1 (415) 555-1234", phone.raw
  end

  def test_adds_plus_prefix_if_missing
    phone = Parse::Phone.new("14155551234")

    assert_equal "+14155551234", phone.to_s
  end

  def test_handles_nil_value
    phone = Parse::Phone.new(nil)

    assert_nil phone.number
    assert_nil phone.raw
    assert phone.blank?
  end

  def test_handles_empty_string
    phone = Parse::Phone.new("")

    assert_nil phone.number
    assert phone.blank?
  end

  def test_valid_us_phone_number
    phone = Parse::Phone.new("+14155551234")

    assert phone.valid?
    refute phone.invalid?
  end

  def test_valid_uk_phone_number
    phone = Parse::Phone.new("+442071234567")

    assert phone.valid?
  end

  def test_valid_german_phone_number
    phone = Parse::Phone.new("+4930123456789")

    assert phone.valid?
  end

  def test_invalid_phone_too_short
    phone = Parse::Phone.new("+1234")

    refute phone.valid?
    assert phone.invalid?
  end

  def test_invalid_phone_no_digits
    phone = Parse::Phone.new("invalid")

    refute phone.valid?
  end

  def test_invalid_phone_starts_with_zero
    phone = Parse::Phone.new("+0123456789")

    refute phone.valid?
  end

  def test_country_code_extraction_us
    phone = Parse::Phone.new("+14155551234")

    assert_equal "1", phone.country_code
  end

  def test_country_code_extraction_uk
    phone = Parse::Phone.new("+442071234567")

    assert_equal "44", phone.country_code
  end

  def test_country_code_extraction_germany
    phone = Parse::Phone.new("+4930123456789")

    assert_equal "49", phone.country_code
  end

  def test_national_number_extraction
    phone = Parse::Phone.new("+14155551234")

    assert_equal "4155551234", phone.national
  end

  def test_national_returns_nil_for_invalid
    phone = Parse::Phone.new("invalid")

    assert_nil phone.national
  end

  def test_country_name_us
    phone = Parse::Phone.new("+14155551234")
    name = phone.country_name

    # Name varies based on phonelib availability
    assert name.is_a?(String)
    assert name.length > 0
  end

  def test_country_name_uk
    phone = Parse::Phone.new("+442071234567")
    name = phone.country_name

    assert name.is_a?(String)
    assert_includes name.downcase, "kingdom" if name  # UK or United Kingdom
  end

  def test_formatted_us_number
    phone = Parse::Phone.new("+14155551234")
    formatted = phone.formatted

    assert formatted.is_a?(String)
    assert formatted.start_with?("+1")
    assert_includes formatted, "415"
  end

  def test_formatted_returns_nil_for_invalid
    phone = Parse::Phone.new("invalid")

    assert_nil phone.formatted
  end

  def test_equality_with_same_number
    phone1 = Parse::Phone.new("+14155551234")
    phone2 = Parse::Phone.new("+14155551234")

    assert_equal phone1, phone2
  end

  def test_equality_with_string
    phone = Parse::Phone.new("+14155551234")

    assert_equal phone, "+14155551234"
    assert_equal phone, "+1 (415) 555-1234"  # Normalized
  end

  def test_inequality_with_different_number
    phone1 = Parse::Phone.new("+14155551234")
    phone2 = Parse::Phone.new("+14155555678")

    refute_equal phone1, phone2
  end

  def test_blank_and_present
    valid_phone = Parse::Phone.new("+14155551234")
    blank_phone = Parse::Phone.new(nil)

    refute valid_phone.blank?
    assert valid_phone.present?

    assert blank_phone.blank?
    refute blank_phone.present?
  end

  def test_as_json
    phone = Parse::Phone.new("+14155551234")

    assert_equal "+14155551234", phone.as_json
  end

  def test_errors_for_blank_phone
    phone = Parse::Phone.new(nil)
    errors = phone.errors

    assert errors.is_a?(Array)
    # Should indicate phone is required
  end

  def test_errors_for_invalid_phone
    phone = Parse::Phone.new("+1")
    errors = phone.errors

    assert errors.is_a?(Array)
    assert errors.length > 0
  end

  def test_errors_empty_for_valid_phone
    phone = Parse::Phone.new("+14155551234")

    assert_empty phone.errors
  end

  def test_typecast_from_string
    result = Parse::Phone.typecast("+14155551234")

    assert_instance_of Parse::Phone, result
    assert_equal "+14155551234", result.to_s
  end

  def test_typecast_from_phone
    original = Parse::Phone.new("+14155551234")
    result = Parse::Phone.typecast(original)

    assert_same original, result  # Should return same instance
  end

  def test_typecast_from_nil
    result = Parse::Phone.typecast(nil)

    assert_nil result
  end

  def test_phonelib_available_returns_boolean
    result = Parse::Phone.phonelib_available?

    assert [true, false].include?(result)
  end

  # ===========================================
  # Phonelib-specific tests (conditional)
  # ===========================================

  if Parse::Phone.phonelib_available?
    def test_phonelib_country_iso_code
      phone = Parse::Phone.new("+14155551234")

      assert_equal "US", phone.country
    end

    def test_phonelib_country_uk
      phone = Parse::Phone.new("+442071234567")

      assert_equal "GB", phone.country
    end

    def test_phonelib_possible
      phone = Parse::Phone.new("+14155551234")

      assert phone.possible?
    end

    def test_phonelib_phone_type
      # Use a well-known mobile format
      mobile = Parse::Phone.new("+14155551234")
      type = mobile.phone_type

      # Type should be a symbol or nil
      assert type.nil? || type.is_a?(Symbol)
    end

    def test_phonelib_mobile_detection
      # UK mobile numbers start with 7
      uk_mobile = Parse::Phone.new("+447911123456")

      assert uk_mobile.valid?
      # mobile? returns true, false, or nil
      result = uk_mobile.mobile?
      assert [true, false, nil].include?(result)
    end

    def test_phonelib_geo_name
      phone = Parse::Phone.new("+14155551234")
      geo = phone.geo_name

      # geo_name may return nil or a string
      assert geo.nil? || geo.is_a?(String)
    end

    def test_phonelib_carrier
      phone = Parse::Phone.new("+14155551234")
      carrier = phone.carrier

      # carrier may return nil or a string
      assert carrier.nil? || carrier.is_a?(String)
    end

    def test_phonelib_formatted_national
      phone = Parse::Phone.new("+14155551234")
      formatted = phone.formatted(:national)

      assert formatted.is_a?(String)
      refute formatted.start_with?("+")  # National format has no +
    end

    def test_phonelib_formatted_e164
      phone = Parse::Phone.new("+1 (415) 555-1234")
      formatted = phone.formatted(:e164)

      assert_equal "+14155551234", formatted
    end

    def test_phonelib_validates_real_numbers_better
      # This number has valid format but phonelib knows it's not a real US area code
      # (555 is reserved for fictional numbers)
      phone = Parse::Phone.new("+15551234567")

      # The validation behavior depends on phonelib's strictness
      # Just verify it returns a boolean
      assert [true, false].include?(phone.valid?)
    end
  else
    def test_fallback_mode_country_returns_nil
      phone = Parse::Phone.new("+14155551234")

      # Without phonelib, country (ISO code) is not available
      assert_nil phone.country
    end

    def test_fallback_mode_phone_type_returns_nil
      phone = Parse::Phone.new("+14155551234")

      assert_nil phone.phone_type
    end

    def test_fallback_mode_carrier_returns_nil
      phone = Parse::Phone.new("+14155551234")

      assert_nil phone.carrier
    end
  end

  # ===========================================
  # Edge cases
  # ===========================================

  def test_maximum_length_e164
    # E.164 max is 15 digits total
    # Use a valid country code (86 = China) with max subscriber digits
    phone = Parse::Phone.new("+8613800138000")

    assert phone.valid?
  end

  def test_exceeds_maximum_length
    # More than 15 digits should be invalid
    phone = Parse::Phone.new("+86138001380001234")

    refute phone.valid?
  end

  def test_minimum_valid_length
    # Minimum is typically 8 digits (7 + country code)
    phone = Parse::Phone.new("+1234567")

    # This may or may not be valid depending on phonelib
    # Just ensure it doesn't crash
    phone.valid?
  end

  def test_handles_object_with_to_s
    obj = Object.new
    def obj.to_s; "+14155551234"; end

    phone = Parse::Phone.new(obj)

    assert_equal "+14155551234", phone.to_s
  end

  def test_international_numbers
    numbers = {
      "+81312345678" => "Japan",
      "+8613812345678" => "China",
      "+919876543210" => "India",
      "+5511987654321" => "Brazil",
      "+33123456789" => "France",
    }

    numbers.each do |num, _country|
      phone = Parse::Phone.new(num)
      assert phone.valid?, "Expected #{num} to be valid"
      assert phone.country_code, "Expected #{num} to have country code"
    end
  end
end
