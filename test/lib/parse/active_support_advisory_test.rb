# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# The gemspec keeps ActiveSupport 6.1 and 7.x installable although those lines
# have no fixed release, so the SDK warns at load time instead.
class ActiveSupportAdvisoryTest < Minitest::Test
  ADVISORY = Parse::Stack::ActiveSupportAdvisory

  def setup
    ADVISORY.reset!
  end

  def teardown
    ADVISORY.reset!
  end

  def test_vulnerable_releases
    %w[6.1.7.10 7.0.8 7.1.5 7.2.3.2 8.0.0 8.0.5.1 8.1.0.beta1 8.1.0 8.1.4].each do |v|
      assert ADVISORY.vulnerable?(v), v
    end
  end

  def test_fixed_and_out_of_scope_releases
    %w[8.0.5.2 8.0.6 8.1.4.1 8.1.5 8.2.0 9.0.0].each do |v|
      refute ADVISORY.vulnerable?(v), v
    end
  end

  def test_warns_once_for_a_vulnerable_release
    _out, err = capture_io { assert ADVISORY.check!("8.1.4") }
    assert_match(/ActiveSupport 8\.1\.4 is affected/, err)
    _out, err = capture_io { refute ADVISORY.check!("8.1.4") }
    assert_empty err
  end

  def test_silent_for_a_fixed_release
    _out, err = capture_io { refute ADVISORY.check!("8.1.4.1") }
    assert_empty err
  end
end
