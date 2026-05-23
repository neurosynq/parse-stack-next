# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/mongodb"
require "date"
require "time"

# Unit tests for Parse::MongoDB.to_mongodb_date helper
# These tests don't require the mongo gem - they test the date conversion utility
class MongoDBDateHelperTest < Minitest::Test
  describe "Parse::MongoDB.to_mongodb_date" do
    describe "with nil" do
      it "returns nil" do
        assert_nil Parse::MongoDB.to_mongodb_date(nil)
      end
    end

    describe "with Time objects" do
      it "converts local time to UTC" do
        local_time = Time.new(2024, 6, 15, 12, 30, 45, "-05:00")
        result = Parse::MongoDB.to_mongodb_date(local_time)

        assert_instance_of Time, result
        assert result.utc?
        assert_equal 2024, result.year
        assert_equal 6, result.month
        assert_equal 15, result.day
        # 12:30 EST = 17:30 UTC
        assert_equal 17, result.hour
        assert_equal 30, result.min
      end

      it "keeps UTC time as UTC" do
        utc_time = Time.utc(2024, 6, 15, 12, 30, 45)
        result = Parse::MongoDB.to_mongodb_date(utc_time)

        assert_instance_of Time, result
        assert result.utc?
        assert_equal 12, result.hour
      end
    end

    describe "with DateTime objects" do
      it "converts DateTime to UTC Time" do
        datetime = DateTime.new(2024, 6, 15, 12, 30, 45, "-05:00")
        result = Parse::MongoDB.to_mongodb_date(datetime)

        assert_instance_of Time, result
        assert result.utc?
        assert_equal 2024, result.year
        assert_equal 6, result.month
        assert_equal 15, result.day
      end
    end

    describe "with Date objects" do
      it "converts Date to midnight UTC" do
        date = Date.new(2024, 6, 15)
        result = Parse::MongoDB.to_mongodb_date(date)

        assert_instance_of Time, result
        assert result.utc?
        assert_equal 2024, result.year
        assert_equal 6, result.month
        assert_equal 15, result.day
        assert_equal 0, result.hour
        assert_equal 0, result.min
        assert_equal 0, result.sec
      end

      it "handles Date.today correctly" do
        today = Date.today
        result = Parse::MongoDB.to_mongodb_date(today)

        assert_instance_of Time, result
        assert result.utc?
        assert_equal today.year, result.year
        assert_equal today.month, result.month
        assert_equal today.day, result.day
      end
    end

    describe "with String dates" do
      it "parses ISO 8601 date-only string to midnight UTC" do
        result = Parse::MongoDB.to_mongodb_date("2024-06-15")

        assert_instance_of Time, result
        assert result.utc?
        assert_equal 2024, result.year
        assert_equal 6, result.month
        assert_equal 15, result.day
        assert_equal 0, result.hour
      end

      it "parses ISO 8601 datetime string to UTC" do
        result = Parse::MongoDB.to_mongodb_date("2024-06-15T14:30:00Z")

        assert_instance_of Time, result
        assert result.utc?
        assert_equal 2024, result.year
        assert_equal 6, result.month
        assert_equal 15, result.day
        assert_equal 14, result.hour
        assert_equal 30, result.min
      end

      it "parses datetime with timezone offset to UTC" do
        result = Parse::MongoDB.to_mongodb_date("2024-06-15T10:30:00-04:00")

        assert_instance_of Time, result
        assert result.utc?
        # 10:30 EDT = 14:30 UTC
        assert_equal 14, result.hour
      end

      it "raises ArgumentError for invalid date strings" do
        assert_raises ArgumentError do
          Parse::MongoDB.to_mongodb_date("not-a-date")
        end
      end
    end

    describe "with Integer (Unix timestamp)" do
      it "converts Unix timestamp to UTC Time" do
        # 2024-06-15 12:30:45 UTC
        timestamp = 1718451045
        result = Parse::MongoDB.to_mongodb_date(timestamp)

        assert_instance_of Time, result
        assert result.utc?
        assert_equal 2024, result.year
        assert_equal 6, result.month
        assert_equal 15, result.day
      end
    end

    describe "with unsupported types" do
      it "raises ArgumentError for arrays" do
        assert_raises ArgumentError do
          Parse::MongoDB.to_mongodb_date([2024, 6, 15])
        end
      end

      it "raises ArgumentError for hashes" do
        assert_raises ArgumentError do
          Parse::MongoDB.to_mongodb_date({ year: 2024, month: 6 })
        end
      end

      it "raises ArgumentError for other objects" do
        assert_raises ArgumentError do
          Parse::MongoDB.to_mongodb_date(Object.new)
        end
      end
    end

    describe "practical use cases" do
      it "can be used for date range queries" do
        start_date = Parse::MongoDB.to_mongodb_date("2024-01-01")
        end_date = Parse::MongoDB.to_mongodb_date("2024-12-31")

        # Both should be comparable UTC times
        assert start_date < end_date
        assert_equal Time.utc(2024, 1, 1), start_date
        assert_equal Time.utc(2024, 12, 31), end_date
      end

      it "handles relative dates correctly" do
        # 30 days ago from a known date
        reference = Date.new(2024, 6, 15)
        cutoff = Parse::MongoDB.to_mongodb_date(reference - 30)

        assert_equal Time.utc(2024, 5, 16), cutoff
      end
    end
  end
end
