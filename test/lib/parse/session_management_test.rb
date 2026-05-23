# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit tests for Parse::Session management functionality
class SessionManagementTest < Minitest::Test

  # ==========================================================================
  # Test 1: Class methods exist
  # ==========================================================================
  def test_class_methods_exist
    puts "\n=== Testing Session Class Methods Exist ==="

    assert_respond_to Parse::Session, :active
    assert_respond_to Parse::Session, :expired
    assert_respond_to Parse::Session, :for_user
    assert_respond_to Parse::Session, :revoke_all_for_user
    assert_respond_to Parse::Session, :active_count_for_user
    assert_respond_to Parse::Session, :session

    puts "Class methods exist!"
  end

  # ==========================================================================
  # Test 2: Instance methods exist
  # ==========================================================================
  def test_instance_methods_exist
    puts "\n=== Testing Session Instance Methods Exist ==="

    session = Parse::Session.new
    assert_respond_to session, :expired?
    assert_respond_to session, :valid?
    assert_respond_to session, :time_remaining
    assert_respond_to session, :expires_within?
    assert_respond_to session, :revoke!

    puts "Instance methods exist!"
  end

  # ==========================================================================
  # Test 3: expired? with nil expires_at
  # ==========================================================================
  def test_expired_with_nil_expires_at
    puts "\n=== Testing expired? with nil expires_at ==="

    session = Parse::Session.new
    # expires_at is nil by default
    refute session.expired?

    puts "expired? with nil expires_at returns false!"
  end

  # ==========================================================================
  # Test 4: expired? with future date
  # ==========================================================================
  def test_expired_with_future_date
    puts "\n=== Testing expired? with future date ==="

    session = Parse::Session.new
    session.expires_at = Time.now + 3600  # 1 hour from now

    refute session.expired?

    puts "expired? with future date returns false!"
  end

  # ==========================================================================
  # Test 5: expired? with past date
  # ==========================================================================
  def test_expired_with_past_date
    puts "\n=== Testing expired? with past date ==="

    session = Parse::Session.new
    session.expires_at = Time.now - 3600  # 1 hour ago

    assert session.expired?

    puts "expired? with past date returns true!"
  end

  # ==========================================================================
  # Test 6: valid? is opposite of expired?
  # ==========================================================================
  def test_valid_is_opposite_of_expired
    puts "\n=== Testing valid? is opposite of expired? ==="

    session = Parse::Session.new
    session.expires_at = Time.now + 3600  # 1 hour from now

    assert session.valid?
    refute session.expired?

    session.expires_at = Time.now - 3600  # 1 hour ago
    refute session.valid?
    assert session.expired?

    puts "valid? is correctly opposite of expired?!"
  end

  # ==========================================================================
  # Test 7: time_remaining with nil expires_at
  # ==========================================================================
  def test_time_remaining_with_nil_expires_at
    puts "\n=== Testing time_remaining with nil expires_at ==="

    session = Parse::Session.new

    assert_nil session.time_remaining

    puts "time_remaining with nil expires_at returns nil!"
  end

  # ==========================================================================
  # Test 8: time_remaining with future date
  # ==========================================================================
  def test_time_remaining_with_future_date
    puts "\n=== Testing time_remaining with future date ==="

    session = Parse::Session.new
    session.expires_at = Time.now + 3600  # 1 hour from now

    remaining = session.time_remaining
    assert remaining > 0
    assert remaining <= 3600

    puts "time_remaining with future date returns positive value!"
  end

  # ==========================================================================
  # Test 9: time_remaining with past date
  # ==========================================================================
  def test_time_remaining_with_past_date
    puts "\n=== Testing time_remaining with past date ==="

    session = Parse::Session.new
    session.expires_at = Time.now - 3600  # 1 hour ago

    assert_equal 0, session.time_remaining

    puts "time_remaining with past date returns 0!"
  end

  # ==========================================================================
  # Test 10: expires_within? with nil expires_at
  # ==========================================================================
  def test_expires_within_with_nil_expires_at
    puts "\n=== Testing expires_within? with nil expires_at ==="

    session = Parse::Session.new

    refute session.expires_within?(3600)

    puts "expires_within? with nil expires_at returns false!"
  end

  # ==========================================================================
  # Test 11: expires_within? with future date within duration
  # ==========================================================================
  def test_expires_within_future_date_within_duration
    puts "\n=== Testing expires_within? with future date within duration ==="

    session = Parse::Session.new
    session.expires_at = Time.now + 1800  # 30 minutes from now

    assert session.expires_within?(3600)  # Expires within 1 hour

    puts "expires_within? correctly detects expiration within duration!"
  end

  # ==========================================================================
  # Test 12: expires_within? with future date outside duration
  # ==========================================================================
  def test_expires_within_future_date_outside_duration
    puts "\n=== Testing expires_within? with future date outside duration ==="

    session = Parse::Session.new
    session.expires_at = Time.now + 7200  # 2 hours from now

    refute session.expires_within?(3600)  # Does NOT expire within 1 hour

    puts "expires_within? correctly returns false when outside duration!"
  end

  # ==========================================================================
  # Test 13: active scope returns Query
  # ==========================================================================
  def test_active_scope_returns_query
    puts "\n=== Testing active Scope Returns Query ==="

    result = Parse::Session.active
    assert_instance_of Parse::Query, result

    puts "active scope returns a Query!"
  end

  # ==========================================================================
  # Test 14: expired scope returns Query
  # ==========================================================================
  def test_expired_scope_returns_query
    puts "\n=== Testing expired Scope Returns Query ==="

    result = Parse::Session.expired
    assert_instance_of Parse::Query, result

    puts "expired scope returns a Query!"
  end

  # ==========================================================================
  # Test 15: for_user scope with user object
  # ==========================================================================
  def test_for_user_scope_with_user_object
    puts "\n=== Testing for_user Scope with User Object ==="

    user = Parse::User.new
    user.id = "test123"

    result = Parse::Session.for_user(user)
    assert_instance_of Parse::Query, result

    puts "for_user scope with user object returns a Query!"
  end

  # ==========================================================================
  # Test 16: for_user scope with string ID
  # ==========================================================================
  def test_for_user_scope_with_string_id
    puts "\n=== Testing for_user Scope with String ID ==="

    result = Parse::Session.for_user("test123")
    assert_instance_of Parse::Query, result

    puts "for_user scope with string ID returns a Query!"
  end
end
