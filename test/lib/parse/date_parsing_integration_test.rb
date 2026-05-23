require_relative "../../test_helper_integration"
require "timeout"

class DateParsingIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  # Timeout helper method
  def with_timeout(seconds, description)
    Timeout.timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{description} timed out after #{seconds} seconds"
  end

  # Test model for date parsing tests
  class DateTestRecord < Parse::Object
    parse_class "DateTestRecord"
    property :name, :string
    property :event_date, :date
    property :start_date, :date
    property :end_date, :date
  end

  def test_save_and_fetch_with_valid_date
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "valid date save and fetch") do
        # Create record with valid date
        record = DateTestRecord.new(
          name: "Valid Date Test",
          event_date: "2025-12-04T15:15:05.446Z"
        )
        assert record.save, "Should save record with valid date"
        assert_instance_of Parse::Date, record.event_date

        # Fetch and verify
        fetched = DateTestRecord.find(record.id)
        assert_instance_of Parse::Date, fetched.event_date
        assert_equal 2025, fetched.event_date.year
        assert_equal 12, fetched.event_date.month
        assert_equal 4, fetched.event_date.day

        puts "Valid date save and fetch passed"
      end
    end
  end

  def test_save_and_fetch_with_nil_date
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "nil date save and fetch") do
        # Create record with nil date
        record = DateTestRecord.new(
          name: "Nil Date Test",
          event_date: nil
        )
        assert record.save, "Should save record with nil date"
        assert_nil record.event_date

        # Fetch and verify
        fetched = DateTestRecord.find(record.id)
        assert_nil fetched.event_date

        puts "Nil date save and fetch passed"
      end
    end
  end

  def test_update_date_to_empty_string
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "update date to empty string") do
        # Create record with valid date first
        record = DateTestRecord.new(
          name: "Empty String Update Test",
          event_date: Time.now.utc
        )
        assert record.save, "Should save record with valid date"
        assert_instance_of Parse::Date, record.event_date

        # Update with empty string (should set to nil)
        record.event_date = ""
        assert_nil record.event_date, "Empty string should result in nil locally"

        assert record.save, "Should save record after setting date to empty string"

        # Fetch and verify
        fetched = DateTestRecord.find(record.id)
        assert_nil fetched.event_date, "Empty string should persist as nil"

        puts "Update date to empty string passed"
      end
    end
  end

  def test_update_date_to_whitespace_string
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "update date to whitespace string") do
        # Create record with valid date first
        record = DateTestRecord.new(
          name: "Whitespace Update Test",
          event_date: Time.now.utc
        )
        assert record.save, "Should save record with valid date"

        # Update with whitespace string (should set to nil)
        record.event_date = "   "
        assert_nil record.event_date, "Whitespace string should result in nil locally"

        assert record.save, "Should save record after setting date to whitespace"

        # Fetch and verify
        fetched = DateTestRecord.find(record.id)
        assert_nil fetched.event_date, "Whitespace string should persist as nil"

        puts "Update date to whitespace string passed"
      end
    end
  end

  def test_date_with_leading_trailing_whitespace_trims_correctly
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "date with whitespace trims correctly") do
        # Create record with whitespace-padded date string
        record = DateTestRecord.new(
          name: "Whitespace Trimming Test",
          event_date: "  2025-06-15T10:30:00.000Z  "
        )
        assert record.save, "Should save record with whitespace-padded date"
        assert_instance_of Parse::Date, record.event_date
        assert_equal 2025, record.event_date.year
        assert_equal 6, record.event_date.month
        assert_equal 15, record.event_date.day

        # Fetch and verify
        fetched = DateTestRecord.find(record.id)
        assert_instance_of Parse::Date, fetched.event_date
        assert_equal 2025, fetched.event_date.year

        puts "Date with whitespace trims correctly passed"
      end
    end
  end

  def test_date_hash_with_empty_iso
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "date hash with empty iso") do
        # Test setting date via hash format with empty iso
        record = DateTestRecord.new(
          name: "Empty ISO Hash Test"
        )
        record.event_date = { "__type" => "Date", "iso" => "" }
        assert_nil record.event_date, "Hash with empty iso should result in nil"

        assert record.save, "Should save record with empty iso hash"

        # Fetch and verify
        fetched = DateTestRecord.find(record.id)
        assert_nil fetched.event_date

        puts "Date hash with empty iso passed"
      end
    end
  end

  def test_date_hash_with_whitespace_iso
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "date hash with whitespace iso") do
        # Test setting date via hash format with whitespace iso
        record = DateTestRecord.new(
          name: "Whitespace ISO Hash Test"
        )
        record.event_date = { "__type" => "Date", "iso" => "   " }
        assert_nil record.event_date, "Hash with whitespace iso should result in nil"

        assert record.save, "Should save record with whitespace iso hash"

        # Fetch and verify
        fetched = DateTestRecord.find(record.id)
        assert_nil fetched.event_date

        puts "Date hash with whitespace iso passed"
      end
    end
  end

  def test_date_hash_with_missing_iso
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "date hash with missing iso") do
        # Test setting date via hash format with missing iso key
        record = DateTestRecord.new(
          name: "Missing ISO Hash Test"
        )
        record.event_date = { "__type" => "Date" }
        assert_nil record.event_date, "Hash with missing iso should result in nil"

        assert record.save, "Should save record with missing iso hash"

        # Fetch and verify
        fetched = DateTestRecord.find(record.id)
        assert_nil fetched.event_date

        puts "Date hash with missing iso passed"
      end
    end
  end

  def test_date_hash_with_valid_iso_and_whitespace
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "date hash with valid iso and whitespace") do
        # Test setting date via hash format with whitespace around valid iso
        record = DateTestRecord.new(
          name: "Valid ISO with Whitespace Test"
        )
        record.event_date = { "__type" => "Date", "iso" => "  2025-07-20T08:00:00.000Z  " }
        assert_instance_of Parse::Date, record.event_date
        assert_equal 2025, record.event_date.year
        assert_equal 7, record.event_date.month
        assert_equal 20, record.event_date.day

        assert record.save, "Should save record with whitespace-padded iso"

        # Fetch and verify
        fetched = DateTestRecord.find(record.id)
        assert_instance_of Parse::Date, fetched.event_date
        assert_equal 2025, fetched.event_date.year

        puts "Date hash with valid iso and whitespace passed"
      end
    end
  end

  def test_query_with_date_fields_after_empty_date_updates
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "query with date fields after empty date updates") do
        # Create records with various date states
        record_with_date = DateTestRecord.new(
          name: "Has Date",
          event_date: Time.now.utc
        )
        assert record_with_date.save

        record_without_date = DateTestRecord.new(
          name: "No Date",
          event_date: ""
        )
        assert record_without_date.save

        record_whitespace_date = DateTestRecord.new(
          name: "Whitespace Date",
          event_date: "   "
        )
        assert record_whitespace_date.save

        # Query for records where event_date exists
        records_with_dates = DateTestRecord.query.where(:event_date.exists => true).results
        has_date_record = records_with_dates.find { |r| r.name == "Has Date" }
        assert has_date_record, "Should find record with date"

        # Query for records where event_date does not exist
        records_without_dates = DateTestRecord.query.where(:event_date.exists => false).results
        no_date_names = records_without_dates.map(&:name)
        assert_includes no_date_names, "No Date", "Should find record without date"
        assert_includes no_date_names, "Whitespace Date", "Should find record with whitespace date"

        puts "Query with date fields after empty date updates passed"
        puts "  - Records with dates: #{records_with_dates.length}"
        puts "  - Records without dates: #{records_without_dates.length}"
      end
    end
  end

  def test_multiple_date_fields_with_mixed_empty_values
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "multiple date fields with mixed empty values") do
        # Create record with multiple date fields, some empty
        record = DateTestRecord.new(
          name: "Mixed Dates Test",
          event_date: "2025-12-04T15:15:05.446Z",
          start_date: "",
          end_date: "   "
        )

        assert_instance_of Parse::Date, record.event_date
        assert_nil record.start_date, "Empty string start_date should be nil"
        assert_nil record.end_date, "Whitespace end_date should be nil"

        assert record.save, "Should save record with mixed date values"

        # Fetch and verify all fields
        fetched = DateTestRecord.find(record.id)
        assert_instance_of Parse::Date, fetched.event_date
        assert_nil fetched.start_date
        assert_nil fetched.end_date

        puts "Multiple date fields with mixed empty values passed"
      end
    end
  end

  def test_batch_create_with_various_date_formats
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "batch create with various date formats") do
        test_cases = [
          { name: "Valid ISO String", event_date: "2025-01-15T10:00:00.000Z", expect_nil: false },
          { name: "Empty String", event_date: "", expect_nil: true },
          { name: "Whitespace Only", event_date: "   ", expect_nil: true },
          { name: "Padded ISO", event_date: "  2025-02-20T14:30:00.000Z  ", expect_nil: false },
          { name: "Hash Empty ISO", event_date: { "__type" => "Date", "iso" => "" }, expect_nil: true },
          { name: "Hash Valid ISO", event_date: { "__type" => "Date", "iso" => "2025-03-25T09:00:00.000Z" }, expect_nil: false },
          { name: "Time Object", event_date: Time.utc(2025, 4, 10, 12, 0, 0), expect_nil: false },
          { name: "Nil Value", event_date: nil, expect_nil: true },
        ]

        created_records = []
        test_cases.each do |tc|
          record = DateTestRecord.new(name: tc[:name], event_date: tc[:event_date])

          if tc[:expect_nil]
            assert_nil record.event_date, "#{tc[:name]}: event_date should be nil before save"
          else
            assert_instance_of Parse::Date, record.event_date, "#{tc[:name]}: event_date should be Parse::Date before save"
          end

          assert record.save, "#{tc[:name]}: should save successfully"
          created_records << { record: record, expect_nil: tc[:expect_nil], name: tc[:name] }
        end

        # Verify all records after fetching
        created_records.each do |cr|
          fetched = DateTestRecord.find(cr[:record].id)
          if cr[:expect_nil]
            assert_nil fetched.event_date, "#{cr[:name]}: event_date should be nil after fetch"
          else
            assert_instance_of Parse::Date, fetched.event_date, "#{cr[:name]}: event_date should be Parse::Date after fetch"
          end
        end

        puts "Batch create with various date formats passed"
        puts "  - Created #{created_records.length} records"
        puts "  - Records with nil dates: #{created_records.count { |r| r[:expect_nil] }}"
        puts "  - Records with valid dates: #{created_records.count { |r| !r[:expect_nil] }}"
      end
    end
  end
end
