# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# The gemspec cannot exclude every vulnerable Rack 3.x release (RubyGems
# limits a requirement string to 255 characters), so the SDK warns at load
# time instead.
class RackAdvisoryTest < Minitest::Test
  ADVISORY = Parse::Stack::RackAdvisory

  def setup
    ADVISORY.reset!
  end

  def teardown
    ADVISORY.reset!
  end

  def test_vulnerable_releases
    %w[3.0.0 3.0.18 3.0.9.1 3.1.0 3.1.20 3.2.0 3.2.5].each do |v|
      assert ADVISORY.vulnerable?(v), v
    end
  end

  def test_fixed_and_out_of_scope_releases
    %w[2.2.23 2.2.24 3.1.21 3.1.22 3.2.6 3.2.7 3.3.0 4.0.0].each do |v|
      refute ADVISORY.vulnerable?(v), v
    end
  end

  def test_warns_once_for_a_vulnerable_release
    _out, err = capture_io { assert ADVISORY.check!("3.2.5") }
    assert_match(/Rack 3\.2\.5 is affected/, err)
    _out, err = capture_io { refute ADVISORY.check!("3.2.5") }
    assert_empty err
  end

  def test_silent_for_a_fixed_release
    _out, err = capture_io { refute ADVISORY.check!("3.2.7") }
    assert_empty err
  end

  def test_gemspec_requirement_fits_rubygems_limit
    spec = Gem::Specification.load(File.expand_path("../../../parse-stack-next.gemspec", __dir__))
    spec.dependencies.each do |dep|
      assert_operator dep.requirement.to_s.length, :<=, 255, "#{dep.name} requirement is too long"
    end
  end
end
