# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module Stack
    # Load-time check for Rack releases affected by the 2026-04 Rack
    # advisories. The fixes are per branch (2.2.23, 3.1.21, 3.2.6, with no
    # fixed 3.0 release). The gemspec floor covers the 2.2 line; RubyGems
    # limits a requirement string to 255 characters, which is too short to
    # exclude each vulnerable 3.x release by name, so a vulnerable 3.x
    # release is reported here instead of being refused at install time.
    module RackAdvisory
      # Lowest fixed release per Rack 3.x minor line; nil means no fix exists
      # on that line.
      FIXED_3X = { "3.0" => nil, "3.1" => "3.1.21", "3.2" => "3.2.6" }.freeze

      module_function

      # Whether a Rack version is on a 3.x line with a known-vulnerable
      # release below its fix.
      # @param version [String, Gem::Version]
      # @return [Boolean]
      def vulnerable?(version)
        v = Gem::Version.new(version.to_s)
        return false unless v.segments.first == 3
        line = v.segments.first(2).join(".")
        return false unless FIXED_3X.key?(line)
        fixed = FIXED_3X[line]
        fixed.nil? || v < Gem::Version.new(fixed)
      end

      # Warn once when the loaded Rack release is vulnerable.
      # @param version [String, Gem::Version, nil] defaults to the activated
      #   rack gem's version.
      # @return [Boolean] true when a warning was printed
      def check!(version = nil)
        version ||= Gem.loaded_specs["rack"]&.version
        return false if version.nil? || @warned
        return false unless vulnerable?(version)
        @warned = true
        warn "[parse-stack-next] Rack #{version} is affected by the 2026-04 Rack " \
             "security advisories. Upgrade to Rack 3.2.6 or later (or 3.1.21 or later " \
             "on the 3.1 line; the 3.0 line has no fixed release)."
        true
      end

      # @!visibility private
      def reset!
        @warned = false
      end
    end
  end
end
