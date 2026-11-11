# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module Stack
    # Load-time check for ActiveSupport releases affected by the 2026
    # ActiveSupport security advisories (GHSA-8474-xrp6-wh69 and
    # GHSA-2w9f-fxwj-w2qf). The fixes are 8.0.5.2 and 8.1.4.1; the 6.1 and
    # 7.x lines have no fixed release. The gemspec keeps those lines
    # installable, so a vulnerable release is reported here instead of being
    # refused at install time. ActiveModel is versioned in lockstep with
    # ActiveSupport, so checking ActiveSupport covers both.
    module ActiveSupportAdvisory
      # Lowest fixed release per affected minor line. Every release below
      # the 8.0 fix is affected, including the unfixed 6.1 and 7.x lines.
      FIXED = { "8.0" => "8.0.5.2", "8.1" => "8.1.4.1" }.freeze

      module_function

      # Whether an ActiveSupport version is a known-vulnerable release.
      # @param version [String, Gem::Version]
      # @return [Boolean]
      def vulnerable?(version)
        v = Gem::Version.new(version.to_s)
        line = v.segments.first(2).join(".")
        fixed = FIXED[line]
        return v < Gem::Version.new(fixed) if fixed
        v < Gem::Version.new(FIXED["8.0"])
      end

      # Warn once when the loaded ActiveSupport release is vulnerable.
      # @param version [String, Gem::Version, nil] defaults to the activated
      #   activesupport gem's version.
      # @return [Boolean] true when a warning was printed
      def check!(version = nil)
        version ||= Gem.loaded_specs["activesupport"]&.version
        return false if version.nil? || @warned
        return false unless vulnerable?(version)
        @warned = true
        warn "[parse-stack-next] ActiveSupport #{version} is affected by the 2026 " \
             "ActiveSupport security advisories. Upgrade to ActiveSupport 8.1.4.1 or " \
             "later (or 8.0.5.2 or later on the 8.0 line; 6.1 and 7.x have no fixed release)."
        true
      end

      # @!visibility private
      def reset!
        @warned = false
      end
    end
  end
end
