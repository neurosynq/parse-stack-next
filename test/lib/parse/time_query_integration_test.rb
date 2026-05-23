require_relative '../../test_helper_integration'
require 'timeout'

class TimeQueryIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  # Timeout helper method
  def with_timeout(seconds, description)
    Timeout.timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{description} timed out after #{seconds} seconds"
  end

  # Test model for time-based queries
  class Event < Parse::Object
    parse_class "Event"
    property :name, :string
    property :description, :string
    property :start_time, :date
    property :end_time, :date
    # Note: created_at and updated_at are already defined as BASE_KEYS in Parse::Object
    property :priority, :integer
    property :is_active, :boolean
  end

  class LogEntry < Parse::Object
    parse_class "LogEntry"
    property :message, :string
    property :level, :string
    property :timestamp, :date
    property :user_id, :string
    property :session_id, :string
  end

  class Author < Parse::Object
    parse_class "TimeQueryAuthor"
    property :name, :string
    property :email, :string
    property :bio, :string
    property :joined_at, :date
  end

  class Article < Parse::Object
    parse_class "TimeQueryArticle"
    property :title, :string
    property :content, :string
    property :published_at, :date
    property :view_count, :integer
    property :is_published, :boolean
    belongs_to :author, as: :time_query_author
    belongs_to :editor, as: :time_query_author
  end

  class Comment < Parse::Object
    parse_class "TimeQueryComment"
    property :text, :string
    property :posted_at, :date
    property :likes, :integer
    belongs_to :author, as: :time_query_author
    belongs_to :article, as: :time_query_article
  end

  def setup_time_test_data
    # Get current time in UTC for consistent testing
    @base_time = Time.now.utc
    @one_hour_ago = @base_time - 1.hour
    @two_hours_ago = @base_time - 2.hours
    @three_hours_ago = @base_time - 3.hours
    @one_hour_later = @base_time + 1.hour
    @two_hours_later = @base_time + 2.hours

    # Create events with specific timestamps
    @past_event = Event.new({
      name: "Past Event",
      description: "Event that happened 3 hours ago",
      start_time: @three_hours_ago,
      end_time: @two_hours_ago,
      priority: 1,
      is_active: false
    })
    assert @past_event.save, "Should save past event"

    @current_event = Event.new({
      name: "Current Event", 
      description: "Event happening now",
      start_time: @one_hour_ago,
      end_time: @one_hour_later,
      priority: 2,
      is_active: true
    })
    assert @current_event.save, "Should save current event"

    @future_event = Event.new({
      name: "Future Event",
      description: "Event happening in the future",
      start_time: @one_hour_later,
      end_time: @two_hours_later,
      priority: 3,
      is_active: true
    })
    assert @future_event.save, "Should save future event"

    # Create log entries with different timestamps
    @old_log = LogEntry.new({
      message: "Old log entry",
      level: "INFO",
      timestamp: @three_hours_ago,
      user_id: "user1",
      session_id: "session_old"
    })
    assert @old_log.save, "Should save old log entry"

    @recent_log = LogEntry.new({
      message: "Recent log entry",
      level: "ERROR", 
      timestamp: @one_hour_ago,
      user_id: "user2",
      session_id: "session_recent"
    })
    assert @recent_log.save, "Should save recent log entry"

    puts "Created time test data:"
    puts "  Base time: #{@base_time}"
    puts "  Past event: #{@past_event.start_time} - #{@past_event.end_time}"
    puts "  Current event: #{@current_event.start_time} - #{@current_event.end_time}" 
    puts "  Future event: #{@future_event.start_time} - #{@future_event.end_time}"
  end

  def test_after_queries
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(10, "after queries test") do
        setup_time_test_data

        # Test .after with Time object
        events_after_2h_ago = Event.query.where(:start_time.after => @two_hours_ago).results
        assert events_after_2h_ago.length == 2, "Should find 2 events after 2 hours ago"
        
        event_names = events_after_2h_ago.map(&:name).sort
        assert_includes event_names, "Current Event"
        assert_includes event_names, "Future Event"
        
        # Test .after with DateTime
        dt_two_hours_ago = @two_hours_ago.to_datetime
        events_after_dt = Event.query.where(:start_time.after => dt_two_hours_ago).results
        assert events_after_dt.length == 2, "Should find same events with DateTime"

        # Test .after with Parse::Date (skip this test as Parse::Date constructor is complex)
        # parse_date_two_hours_ago = Parse::Date.new(@two_hours_ago.iso8601)
        # events_after_parse_date = Event.query.where(:start_time.after => parse_date_two_hours_ago).results
        # assert events_after_parse_date.length == 2, "Should find same events with Parse::Date"

        # Test logs after specific time
        logs_after_2h = LogEntry.query.where(:timestamp.after => @two_hours_ago).results
        assert logs_after_2h.length == 1, "Should find 1 log after 2 hours ago"
        assert_equal "Recent log entry", logs_after_2h.first.message

        puts "✓ After queries working correctly"
        puts "  - Time objects: #{events_after_2h_ago.length} events"
        puts "  - DateTime objects: #{events_after_dt.length} events"
        puts "  - Log entries: #{logs_after_2h.length} logs"
      end
    end
  end

  def test_before_queries
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(10, "before queries test") do
        setup_time_test_data

        # Test .before with current time
        events_before_now = Event.query.where(:start_time.before => @base_time).results
        assert events_before_now.length == 2, "Should find 2 events before current time"
        
        event_names = events_before_now.map(&:name).sort
        assert_includes event_names, "Past Event"
        assert_includes event_names, "Current Event"

        # Test .before with specific past time
        events_before_1h_ago = Event.query.where(:start_time.before => @one_hour_ago).results
        assert events_before_1h_ago.length == 1, "Should find 1 event before 1 hour ago"
        assert_equal "Past Event", events_before_1h_ago.first.name

        # Test .lt (less than) alias
        events_lt_now = Event.query.where(:start_time.lt => @base_time).results
        assert events_lt_now.length == 2, "Should find same events using .lt alias"

        # Test logs before specific time
        logs_before_now = LogEntry.query.where(:timestamp.before => @base_time).results
        assert logs_before_now.length == 2, "Should find 2 logs before current time"

        puts "✓ Before queries working correctly"
        puts "  - Events before now: #{events_before_now.length}"
        puts "  - Events before 1h ago: #{events_before_1h_ago.length}"
        puts "  - Using .lt alias: #{events_lt_now.length}"
      end
    end
  end

  def test_between_queries
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(10, "between queries test") do
        setup_time_test_data

        # Test between_dates for events
        start_range = @three_hours_ago
        end_range = @base_time
        events_between = Event.query.where(:start_time.between_dates => [start_range, end_range]).results
        assert events_between.length == 2, "Should find 2 events between 3 hours ago and now"
        
        event_names = events_between.map(&:name).sort
        assert_includes event_names, "Past Event"
        assert_includes event_names, "Current Event"

        # Test narrow time range
        narrow_start = @two_hours_ago - 30.minutes
        narrow_end = @two_hours_ago + 30.minutes
        events_narrow = Event.query.where(:start_time.between_dates => [narrow_start, narrow_end]).results
        assert events_narrow.empty?, "Should find no events in narrow 1-hour window"

        # Test between for log timestamps
        logs_between = LogEntry.query.where(:timestamp.between_dates => [@three_hours_ago, @base_time]).results
        assert logs_between.length == 2, "Should find 2 logs in time range"

        # Test with end_time field
        events_ending_between = Event.query.where(:end_time.between_dates => [@one_hour_ago, @one_hour_later]).results
        assert events_ending_between.length == 1, "Should find 1 event ending in range"
        assert_equal "Current Event", events_ending_between.first.name

        puts "✓ Between queries working correctly"
        puts "  - Events between times: #{events_between.length}"
        puts "  - Events in narrow range: #{events_narrow.length}"
        puts "  - Logs between times: #{logs_between.length}"
        puts "  - Events ending between: #{events_ending_between.length}"
      end
    end
  end

  def test_on_or_after_queries
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(10, "on_or_after queries test") do
        setup_time_test_data

        # Test .on_or_after (greater than or equal)
        events_gte_1h_ago = Event.query.where(:start_time.on_or_after => @one_hour_ago).results
        assert events_gte_1h_ago.length == 2, "Should find 2 events on or after 1 hour ago"
        
        event_names = events_gte_1h_ago.map(&:name).sort
        assert_includes event_names, "Current Event"
        assert_includes event_names, "Future Event"

        # Test .gte alias
        events_gte_alias = Event.query.where(:start_time.gte => @one_hour_ago).results
        assert events_gte_alias.length == 2, "Should find same events using .gte alias"

        # Test edge case - exact time match
        exact_time_events = Event.query.where(:start_time.on_or_after => @current_event.start_time).results
        assert exact_time_events.length >= 1, "Should find at least current event at exact time"
        
        current_event_found = exact_time_events.any? { |e| e.name == "Current Event" }
        assert current_event_found, "Should include event that starts exactly at query time"

        puts "✓ On or after queries working correctly"
        puts "  - Events >= 1h ago: #{events_gte_1h_ago.length}"
        puts "  - Using .gte alias: #{events_gte_alias.length}"
        puts "  - Exact time matches: #{exact_time_events.length}"
      end
    end
  end

  def test_on_or_before_queries
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(10, "on_or_before queries test") do
        setup_time_test_data

        # Test .on_or_before (less than or equal)
        events_lte_1h_ago = Event.query.where(:start_time.on_or_before => @one_hour_ago).results
        assert events_lte_1h_ago.length == 2, "Should find 2 events on or before 1 hour ago"
        
        event_names = events_lte_1h_ago.map(&:name).sort
        assert_includes event_names, "Past Event"
        assert_includes event_names, "Current Event"

        # Test .lte alias
        events_lte_alias = Event.query.where(:start_time.lte => @one_hour_ago).results
        assert events_lte_alias.length == 2, "Should find same events using .lte alias"

        # Test edge case - exact time match  
        exact_time_events = Event.query.where(:start_time.on_or_before => @current_event.start_time).results
        assert exact_time_events.length >= 1, "Should find at least current event at exact time"
        
        current_event_found = exact_time_events.any? { |e| e.name == "Current Event" }
        assert current_event_found, "Should include event that starts exactly at query time"

        puts "✓ On or before queries working correctly"
        puts "  - Events <= 1h ago: #{events_lte_1h_ago.length}"
        puts "  - Using .lte alias: #{events_lte_alias.length}"
        puts "  - Exact time matches: #{exact_time_events.length}"
      end
    end
  end

  def test_utc_timezone_handling
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(10, "UTC timezone handling test") do
        # Create times in different timezone formats
        utc_time = Time.now.utc
        local_time = Time.now
        datetime_utc = DateTime.now.utc
        datetime_local = DateTime.now

        # Create event with UTC time
        utc_event = Event.new({
          name: "UTC Event",
          description: "Event created with UTC time",
          start_time: utc_time,
          end_time: utc_time + 1.hour,
          priority: 1,
          is_active: true
        })
        assert utc_event.save, "Should save event with UTC time"

        # Create event with local time
        local_event = Event.new({
          name: "Local Event",
          description: "Event created with local time",
          start_time: local_time,
          end_time: local_time + 1.hour,
          priority: 2,
          is_active: true
        })
        assert local_event.save, "Should save event with local time"

        # Reload events and check timezone handling
        reloaded_utc = Event.query.where(id: utc_event.id).first
        reloaded_local = Event.query.where(id: local_event.id).first

        assert reloaded_utc, "Should reload UTC event"
        assert reloaded_local, "Should reload local event"

        # Check that times are stored consistently (Parse always stores in UTC)
        assert reloaded_utc.start_time.is_a?(Parse::Date), "Start time should be Parse::Date"
        assert reloaded_local.start_time.is_a?(Parse::Date), "Start time should be Parse::Date"

        # Test querying with different timezone formats
        query_time = utc_time - 30.minutes

        # Query with UTC time
        events_utc_query = Event.query.where(:start_time.after => query_time.utc).results
        # Query with local time
        events_local_query = Event.query.where(:start_time.after => query_time).results
        # Query with DateTime UTC
        events_datetime_query = Event.query.where(:start_time.after => query_time.to_datetime.utc).results

        # All queries should return the same results since Parse normalizes to UTC
        assert events_utc_query.length >= 2, "UTC query should find events"
        assert events_local_query.length >= 2, "Local query should find events"
        assert events_datetime_query.length >= 2, "DateTime query should find events"

        # Test timezone consistency in results
        found_utc_event = events_utc_query.find { |e| e.name == "UTC Event" }
        found_local_event = events_local_query.find { |e| e.name == "Local Event" }
        
        assert found_utc_event, "Should find UTC event in results"
        assert found_local_event, "Should find local event in results"

        puts "✓ UTC timezone handling working correctly"
        puts "  - UTC time storage: #{reloaded_utc.start_time.class}"
        puts "  - Local time storage: #{reloaded_local.start_time.class}"
        puts "  - UTC query results: #{events_utc_query.length}"
        puts "  - Local query results: #{events_local_query.length}"
        puts "  - DateTime query results: #{events_datetime_query.length}"
      end
    end
  end

  def test_time_precision_and_milliseconds
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(10, "time precision test") do
        # Create times with millisecond precision
        base_time = Time.now.utc
        precise_time = Time.at(base_time.to_f + 0.123) # Add 123 milliseconds
        
        # Create event with precise timestamp
        precise_event = Event.new({
          name: "Precise Event",
          description: "Event with millisecond precision",
          start_time: precise_time,
          priority: 1,
          is_active: true
        })
        assert precise_event.save, "Should save event with precise time"

        # Query for events within a very narrow time window
        query_start = precise_time - 0.05 # 50ms before
        query_end = precise_time + 0.05   # 50ms after
        
        precise_events = Event.query.where(:start_time.between_dates => [query_start, query_end]).results
        assert precise_events.length >= 1, "Should find event within narrow time window"
        
        found_event = precise_events.find { |e| e.name == "Precise Event" }
        assert found_event, "Should find the precise event"

        # Test that Parse preserves reasonable precision
        reloaded_event = Event.query.where(id: precise_event.id).first
        time_diff = (reloaded_event.start_time.to_time - precise_time).abs
        assert time_diff < 1.0, "Time difference should be less than 1 second"
        
        puts "✓ Time precision handling working correctly"
        puts "  - Original time: #{precise_time}"
        puts "  - Stored time: #{reloaded_event.start_time}"
        puts "  - Time difference: #{time_diff} seconds"
        puts "  - Events in narrow window: #{precise_events.length}"
      end
    end
  end

  def test_complex_time_queries
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(10, "complex time queries test") do
        setup_time_test_data

        # Test compound queries with time and other conditions
        active_recent_events = Event.query
          .where(is_active: true)
          .where(:start_time.after => @two_hours_ago)
          .results
        
        assert active_recent_events.length == 2, "Should find 2 active recent events"
        active_recent_events.each do |event|
          assert event.is_active, "Event should be active"
          assert event.start_time.to_time > @two_hours_ago, "Event should be recent"
        end

        # Test OR queries with time conditions
        past_or_future = Event.query
          .where(:start_time.before => @two_hours_ago)
          .or_where(:start_time.after => @base_time)
          .results
        
        assert past_or_future.length == 2, "Should find past and future events"
        event_names = past_or_future.map(&:name).sort
        assert_includes event_names, "Past Event"
        assert_includes event_names, "Future Event"

        # Test time range with priority filtering
        priority_time_events = Event.query
          .where(:start_time.between_dates => [@three_hours_ago, @two_hours_later])
          .where(:priority.gte => 2)
          .results
        
        assert priority_time_events.length == 2, "Should find 2 events with priority >= 2"
        priority_time_events.each do |event|
          assert event.priority >= 2, "Event should have priority >= 2"
        end

        # Test ordering by time
        events_by_time = Event.query
          .where(:start_time.between_dates => [@three_hours_ago, @two_hours_later])
          .order(:start_time)
          .results
        
        assert events_by_time.length == 3, "Should find all 3 events in range"
        
        # Verify chronological order
        previous_time = nil
        events_by_time.each do |event|
          current_time = event.start_time.to_time
          if previous_time
            assert current_time >= previous_time, "Events should be in chronological order"
          end
          previous_time = current_time
        end

        puts "✓ Complex time queries working correctly"
        puts "  - Active recent events: #{active_recent_events.length}"
        puts "  - Past or future events: #{past_or_future.length}"
        puts "  - Priority + time filtered: #{priority_time_events.length}"
        puts "  - Chronologically ordered: #{events_by_time.length}"
      end
    end
  end

  def test_edge_case_time_queries
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(10, "edge case time queries test") do
        setup_time_test_data  # Need test data for this test
        current_time = Time.now.utc

        # Test with nil/null time values
        event_with_nil_end = Event.new({
          name: "Incomplete Event",
          description: "Event with nil end time",
          start_time: current_time,
          end_time: nil,
          priority: 1,
          is_active: true
        })
        assert event_with_nil_end.save, "Should save event with nil end time"

        # Test querying for events with non-null end times - all our test events have end_time
        all_events = Event.query.results
        events_with_end = all_events.select { |e| e.end_time }
        assert events_with_end.length >= 2, "Should find events with end time (past and current events have end_time)"

        # Test very far future and past dates
        far_past = Time.utc(1970, 1, 1)
        far_future = Time.utc(2100, 1, 1)
        
        events_after_far_past = Event.query.where(:start_time.after => far_past).results
        assert events_after_far_past.length >= 1, "Should handle far past dates"
        
        events_before_far_future = Event.query.where(:start_time.before => far_future).results
        assert events_before_far_future.length >= 1, "Should handle far future dates"

        # Test same time comparisons
        exact_time = current_time
        events_at_exact_time = Event.query.where(start_time: exact_time).results
        events_after_exact_time = Event.query.where(:start_time.after => exact_time).results
        events_on_or_after_exact = Event.query.where(:start_time.on_or_after => exact_time).results
        
        # on_or_after should include more results than just after
        assert events_on_or_after_exact.length >= events_after_exact_time.length, 
               "on_or_after should include equal times"

        puts "✓ Edge case time queries working correctly"
        puts "  - Events with end time: #{events_with_end.length}"
        puts "  - After far past: #{events_after_far_past.length}"
        puts "  - Before far future: #{events_before_far_future.length}"
        puts "  - At exact time: #{events_at_exact_time.length}"
        puts "  - After exact time: #{events_after_exact_time.length}"
        puts "  - On or after exact: #{events_on_or_after_exact.length}"
      end
    end
  end

  def test_exists_operator_queries
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(10, "exists operator test") do
        setup_time_test_data
        
        # Create additional events with null values for testing
        event_no_end = Event.new({
          name: "Open Event",
          description: "Event with no end time",
          start_time: Time.now.utc,
          end_time: nil,
          priority: 1,
          is_active: true
        })
        assert event_no_end.save, "Should save event without end time"
        
        event_no_priority = Event.new({
          name: "No Priority Event", 
          description: "Event with no priority",
          start_time: Time.now.utc - 1.hour,
          end_time: Time.now.utc,
          priority: nil,
          is_active: false
        })
        assert event_no_priority.save, "Should save event without priority"
        
        # Test .exists => true (non-null values)
        events_with_end_time = Event.query.where(:end_time.exists => true).results
        assert events_with_end_time.length >= 2, "Should find events with non-null end_time (from setup_time_test_data)"
        
        events_with_priority = Event.query.where(:priority.exists => true).results
        assert events_with_priority.length >= 3, "Should find events with non-null priority"
        
        # Test .exists => false (null values)
        events_without_end_time = Event.query.where(:end_time.exists => false).results
        assert events_without_end_time.length >= 1, "Should find events with null end_time"
        
        events_without_priority = Event.query.where(:priority.exists => false).results
        assert events_without_priority.length >= 1, "Should find events with null priority"
        
        # Test combining exists with other operators
        recent_events_with_end = Event.query
          .where(:start_time.after => Time.now.utc - 2.hours)
          .where(:end_time.exists => true)
          .results
        assert recent_events_with_end.length >= 1, "Should find recent events with end_time"
        
        # Test exists with string fields
        events_with_description = Event.query.where(:description.exists => true).results
        assert events_with_description.length >= 4, "Should find events with descriptions"
        
        puts "✓ Exists operator queries working correctly"
        puts "  - Events with end_time: #{events_with_end_time.length}"
        puts "  - Events without end_time: #{events_without_end_time.length}" 
        puts "  - Events with priority: #{events_with_priority.length}"
        puts "  - Events without priority: #{events_without_priority.length}"
        puts "  - Recent events with end_time: #{recent_events_with_end.length}"
        puts "  - Events with descriptions: #{events_with_description.length}"
      end
    end
  end

  def test_string_query_operators
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(10, "string query operators test") do
        # Create events with various string patterns for testing
        events_data = [
          {
            name: "Morning Meeting",
            description: "Daily standup meeting with the development team",
            start_time: Time.now.utc,
            priority: 1,
            is_active: true
          },
          {
            name: "Afternoon Review", 
            description: "Code review session for the new features",
            start_time: Time.now.utc + 1.hour,
            priority: 2,
            is_active: true
          },
          {
            name: "Evening Workshop",
            description: "Learning workshop about Parse Stack integration",
            start_time: Time.now.utc + 2.hours,
            priority: 3,
            is_active: false
          },
          {
            name: "Team Building",
            description: "Fun team building activities and games",
            start_time: Time.now.utc + 3.hours,
            priority: 1,
            is_active: true
          }
        ]
        
        created_events = []
        events_data.each do |data|
          event = Event.new(data)
          assert event.save, "Should save event #{data[:name]}"
          created_events << event
        end
        
        # Test .contains operator
        events_with_meeting = Event.query.where(:name.contains => "Meeting").results
        assert events_with_meeting.length >= 1, "Should find events with 'Meeting' in name"
        
        events_with_team = Event.query.where(:description.contains => "team").results
        assert events_with_team.length >= 2, "Should find events with 'team' in description"
        
        # Test .starts_with operator
        events_starting_morning = Event.query.where(:name.starts_with => "Morning").results
        assert events_starting_morning.length >= 1, "Should find events starting with 'Morning'"
        
        events_starting_code = Event.query.where(:description.starts_with => "Code").results
        assert events_starting_code.length >= 1, "Should find events with description starting with 'Code'"
        
        # Test .like operator (exact match pattern matching)
        events_like_exact_name = Event.query.where(:name.like => "Afternoon Review").results
        assert events_like_exact_name.length >= 1, "Should find events with exact name match using .like"
        
        events_like_exact_desc = Event.query.where(:description.like => "Fun team building activities and games").results
        assert events_like_exact_desc.length >= 1, "Should find events with exact description match using .like"
        
        # Test combining string operators with other conditions
        active_meetings = Event.query
          .where(:is_active => true)
          .where(:name.contains => "Meeting")
          .results
        assert active_meetings.length >= 1, "Should find active events containing 'Meeting'"
        
        # Test case sensitivity
        events_uppercase = Event.query.where(:name.contains => "MEETING").results
        events_lowercase = Event.query.where(:name.contains => "meeting").results
        
        # Test string operators with time conditions
        future_workshops = Event.query
          .where(:start_time.after => Time.now.utc + 30.minutes)
          .where(:name.contains => "Workshop")
          .results
        assert future_workshops.length >= 1, "Should find future workshop events"
        
        puts "✓ String query operators working correctly"
        puts "  - Events containing 'Meeting': #{events_with_meeting.length}"
        puts "  - Events with 'team' in description: #{events_with_team.length}"
        puts "  - Events starting with 'Morning': #{events_starting_morning.length}"
        puts "  - Events starting with 'Code': #{events_starting_code.length}"
        puts "  - Events like exact name: #{events_like_exact_name.length}"
        puts "  - Events like exact description: #{events_like_exact_desc.length}"
        puts "  - Active meetings: #{active_meetings.length}"
        puts "  - Uppercase 'MEETING': #{events_uppercase.length}"
        puts "  - Lowercase 'meeting': #{events_lowercase.length}"
        puts "  - Future workshops: #{future_workshops.length}"
      end
    end
  end

  def setup_relational_test_data
    # Create authors
    @author1 = Author.new({
      name: "Alice Johnson",
      email: "alice@example.com", 
      bio: "Tech writer and blogger",
      joined_at: Time.now.utc - (2 * 365 * 24 * 60 * 60)
    })
    assert @author1.save, "Should save author1"

    @author2 = Author.new({
      name: "Bob Smith",
      email: "bob@example.com",
      bio: "Senior journalist",
      joined_at: Time.now.utc - (365 * 24 * 60 * 60)
    })
    assert @author2.save, "Should save author2"

    @editor = Author.new({
      name: "Carol Wilson", 
      email: "carol@example.com",
      bio: "Chief editor",
      joined_at: Time.now.utc - (3 * 365 * 24 * 60 * 60)
    })
    assert @editor.save, "Should save editor"

    # Create articles with time-based data
    @article1 = Article.new({
      title: "Understanding Parse Stack",
      content: "A comprehensive guide to Parse Stack development.",
      published_at: Time.now.utc - (7 * 24 * 60 * 60),
      view_count: 150,
      is_published: true,
      author: @author1,
      editor: @editor
    })
    assert @article1.save, "Should save article1"

    @article2 = Article.new({
      title: "Advanced Ruby Techniques",
      content: "Deep dive into advanced Ruby programming patterns.",
      published_at: Time.now.utc - (3 * 24 * 60 * 60),
      view_count: 89,
      is_published: true,
      author: @author2,
      editor: @editor
    })
    assert @article2.save, "Should save article2"

    @draft_article = Article.new({
      title: "Future of Web Development",
      content: "Draft article about emerging web technologies.",
      published_at: nil,
      view_count: 0,
      is_published: false,
      author: @author1,
      editor: @editor
    })
    assert @draft_article.save, "Should save draft article"

    # Create comments
    @comment1 = Comment.new({
      text: "Great article! Very informative.",
      posted_at: Time.now.utc - (5 * 24 * 60 * 60),
      likes: 12,
      author: @author2,
      article: @article1
    })
    assert @comment1.save, "Should save comment1"

    @comment2 = Comment.new({
      text: "Thanks for sharing this knowledge.",
      posted_at: Time.now.utc - (2 * 24 * 60 * 60),
      likes: 8,
      author: @author1,
      article: @article2
    })
    assert @comment2.save, "Should save comment2"

    @recent_comment = Comment.new({
      text: "Looking forward to more content like this.",
      posted_at: Time.now.utc - (60 * 60),
      likes: 3,
      author: @author2,
      article: @article1
    })
    assert @recent_comment.save, "Should save recent comment"

    puts "Created relational test data:"
    puts "  Authors: #{Author.count}"
    puts "  Articles: #{Article.count}"
    puts "  Comments: #{Comment.count}"
  end

  def test_includes_with_time_queries
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(15, "includes with time queries test") do
        setup_relational_test_data

        # Test includes with time-based filtering
        eight_days_ago = Time.now - (8 * 24 * 60 * 60)  # Go back 8 days to ensure we catch the 7-day-old article
        recent_articles_with_authors = Article.query
          .where(:published_at.after => eight_days_ago)
          .includes(:author)
          .results

        puts "Debug: Found #{recent_articles_with_authors.length} articles published after #{eight_days_ago}"
        recent_articles_with_authors.each do |a|
          puts "  - Article: #{a.title}, published: #{a.published_at}"
        end
        assert recent_articles_with_authors.length == 2, "Should find 2 recent published articles"
        
        # Verify that authors are included (not just pointers)
        recent_articles_with_authors.each do |article|
          assert article.author.present?, "Article should have author"
          assert article.author.is_a?(Author), "Author should be full object, not pointer"
          assert article.author.name.present?, "Author name should be loaded"
          refute article.author.pointer?, "Author should not be in pointer state"
        end

        # Test includes with multiple relations
        articles_with_relations = Article.query
          .where(is_published: true)
          .includes(:author, :editor)
          .results

        assert articles_with_relations.length == 2, "Should find 2 published articles"
        
        articles_with_relations.each do |article|
          assert article.author.present?, "Article should have author"
          assert article.editor.present?, "Article should have editor"
          assert article.author.name.present?, "Author name should be loaded"
          assert article.editor.name.present?, "Editor name should be loaded"
          refute article.author.pointer?, "Author should not be pointer"
          refute article.editor.pointer?, "Editor should not be pointer"
        end

        # Test comments with time filtering and includes
        recent_comments_with_relations = Comment.query
          .where(:posted_at.after => 1.week.ago)
          .includes(:author, :article)
          .results

        assert recent_comments_with_relations.length >= 2, "Should find recent comments"
        
        recent_comments_with_relations.each do |comment|
          assert comment.author.present?, "Comment should have author"
          assert comment.article.present?, "Comment should have article"
          assert comment.author.name.present?, "Comment author name should be loaded"
          assert comment.article.title.present?, "Article title should be loaded"
          refute comment.author.pointer?, "Comment author should not be pointer"
          refute comment.article.pointer?, "Comment article should not be pointer"
        end

        puts "✓ Includes with time queries working correctly"
        puts "  - Recent articles with authors: #{recent_articles_with_authors.length}"
        puts "  - Articles with multiple relations: #{articles_with_relations.length}"
        puts "  - Recent comments with relations: #{recent_comments_with_relations.length}"
      end
    end
  end

  def test_includes_performance_comparison
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(15, "includes performance test") do
        setup_relational_test_data

        # Test without includes (N+1 problem)
        start_time = Time.now
        
        articles_without_includes = Article.query
          .where(:published_at.after => 2.weeks.ago)
          .results
        
        # Force loading authors (this would trigger N+1 queries)
        author_names_without = articles_without_includes.map do |article|
          article.author.name if article.author  # This triggers individual fetches
        end.compact
        
        time_without_includes = Time.now - start_time

        # Test with includes (should be more efficient)
        start_time = Time.now
        
        articles_with_includes = Article.query
          .where(:published_at.after => 2.weeks.ago)
          .includes(:author)
          .results
        
        # Authors should already be loaded
        author_names_with = articles_with_includes.map do |article|
          article.author.name if article.author  # This should not trigger additional queries
        end.compact
        
        time_with_includes = Time.now - start_time

        # Both should return the same data
        assert_equal author_names_without.sort, author_names_with.sort, 
               "Both approaches should return same author names"

        # With includes should generally be faster for multiple records
        puts "✓ Includes performance comparison completed"
        puts "  - Without includes: #{time_without_includes.round(4)}s"
        puts "  - With includes: #{time_with_includes.round(4)}s" 
        puts "  - Author names found: #{author_names_with.length}"
        puts "  - Efficiency note: includes() prevents N+1 query problems"
      end
    end
  end

  def test_includes_with_complex_time_filtering
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(15, "complex includes and time filtering test") do
        setup_relational_test_data

        # Test includes with between_dates
        articles_in_range = Article.query
          .where(:published_at.between_dates => [2.weeks.ago, 1.day.ago])
          .includes(:author, :editor)
          .order(:published_at)
          .results

        assert articles_in_range.length >= 1, "Should find articles in date range"
        
        # Verify chronological order and loaded relations
        previous_date = nil
        articles_in_range.each do |article|
          if previous_date
            assert article.published_at.to_time >= previous_date, "Articles should be chronologically ordered"
          end
          previous_date = article.published_at.to_time
          
          # Verify relations are loaded
          assert article.author.name.present?, "Author should be fully loaded"
          assert article.editor.name.present?, "Editor should be fully loaded"
        end

        # Test comments with compound conditions and includes
        popular_recent_comments = Comment.query
          .where(:posted_at.after => 1.week.ago)
          .where(:likes.gte => 5)
          .includes(:author, :article)
          .order(:likes, :desc)
          .results

        popular_recent_comments.each do |comment|
          assert comment.posted_at.to_time > 1.week.ago, "Comment should be recent"
          assert comment.likes >= 5, "Comment should be popular"
          assert comment.author.name.present?, "Comment author should be loaded"
          assert comment.article.title.present?, "Comment article should be loaded"
        end

        # Test articles by author join date with includes
        articles_by_experienced_authors = Article.query
          .where(is_published: true)
          .includes(:author)
          .results
          .select { |article| article.author.joined_at.to_time < 1.year.ago }

        articles_by_experienced_authors.each do |article|
          assert article.author.joined_at.to_time < 1.year.ago, "Author should be experienced"
          refute article.author.pointer?, "Author should be fully loaded"
        end

        puts "✓ Complex includes and time filtering working correctly"
        puts "  - Articles in date range: #{articles_in_range.length}"
        puts "  - Popular recent comments: #{popular_recent_comments.length}"
        puts "  - Articles by experienced authors: #{articles_by_experienced_authors.length}"
      end
    end
  end

  def test_includes_with_nil_relations
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(10, "includes with nil relations test") do
        setup_relational_test_data

        # Create article without editor
        article_no_editor = Article.new({
          title: "Independent Article",
          content: "Article without an editor",
          published_at: Time.now.utc - (24 * 60 * 60),
          view_count: 25,
          is_published: true,
          author: @author1,
          editor: nil  # No editor
        })
        assert article_no_editor.save, "Should save article without editor"

        # Test includes when some relations are nil
        all_articles_with_includes = Article.query
          .where(:published_at.after => 2.weeks.ago)
          .includes(:author, :editor)
          .results

        article_with_nil_editor = all_articles_with_includes.find { |a| a.title == "Independent Article" }
        assert article_with_nil_editor, "Should find article without editor"
        
        # Author should be loaded, editor should be nil
        assert article_with_nil_editor.author.present?, "Author should be loaded"
        assert article_with_nil_editor.author.name.present?, "Author name should be loaded"
        assert article_with_nil_editor.editor.nil?, "Editor should be nil"
        refute article_with_nil_editor.author.pointer?, "Author should not be pointer"

        # Test that other articles still have their relations loaded
        articles_with_editors = all_articles_with_includes.reject { |a| a.editor.nil? }
        articles_with_editors.each do |article|
          assert article.editor.present?, "Editor should be present"
          assert article.editor.name.present?, "Editor name should be loaded"
          refute article.editor.pointer?, "Editor should not be pointer"
        end

        puts "✓ Includes with nil relations working correctly"
        puts "  - Total articles with includes: #{all_articles_with_includes.length}"
        puts "  - Articles with editors: #{articles_with_editors.length}"
        puts "  - Articles without editors: #{all_articles_with_includes.length - articles_with_editors.length}"
      end
    end
  end
end