# frozen_string_literal: true

require "json"
require "fileutils"

# Snapshot-testing harness for Parse::Query compile output, ACLScope/CLPScope
# pipeline injection, and Atlas Search $search stage construction.
#
# Snapshots live under test/snapshots/<group>/<name>.json. The compiled
# payload is normalized (volatile fields scrubbed, hash keys sorted, certain
# Set-derived arrays sorted) before comparison so the snapshot only fails on
# a real shape change.
#
# Set UPDATE_SNAPSHOTS=1 to (re)write fixtures instead of asserting against
# them. With the env var off, a missing snapshot FAILS rather than silently
# auto-writes — otherwise a never-asserted fixture can sneak through CI.
module SnapshotHelper
  SNAPSHOT_ROOT = File.expand_path("../snapshots", __dir__)

  # 24-hex BSON ObjectId — unique enough to scrub globally.
  MONGO_OID_RE = /\A[a-f0-9]{24}\z/.freeze
  # ISO-8601 timestamp at the start of the string.
  ISO_TIME_RE  = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/.freeze
  # Parse objectIds are [A-Za-z0-9]{10}. That pattern matches plenty of
  # plain English words ("sequential", "ascending"), so we only scrub when
  # the hash key tells us we're looking at one.
  PARSE_OID_RE = /\A[A-Za-z0-9]{10}\z/.freeze
  OBJECT_ID_KEYS = %w[objectId _id parent_object_id].freeze

  # Hash keys whose Array values come from a Ruby Set (or are otherwise
  # genuinely order-independent) — sorting these before snapshotting avoids
  # spurious diffs. Do NOT add `$and`, `$or`, `$nor`: those preserve clause
  # order semantically and reordering them would mask a real regression.
  SORTED_ARRAY_KEYS = %w[$in $nin $all _rperm _wperm permission_strings].freeze

  def self.write?
    ENV["UPDATE_SNAPSHOTS"] == "1"
  end

  # @param value the (already JSON-roundtripped) payload to normalize.
  # @param parent_key [String, nil] the hash key under which `value` lives;
  #   enables key-scoped substitutions like Parse objectId scrubbing.
  def self.normalize(value, parent_key: nil)
    case value
    when Hash
      pairs = value.map do |k, v|
        key = k.to_s
        normalized = normalize(v, parent_key: key)
        if v.is_a?(Array) && SORTED_ARRAY_KEYS.include?(key) &&
           normalized.all? { |x| x.is_a?(String) || x.is_a?(Numeric) }
          normalized = normalized.sort_by(&:to_s)
        end
        [key, normalized]
      end
      pairs.sort_by(&:first).to_h
    when Array
      value.map { |v| normalize(v, parent_key: parent_key) }
    when String
      if value.match?(MONGO_OID_RE)
        "<<MONGO_OID>>"
      elsif value.match?(ISO_TIME_RE)
        "<<TIMESTAMP>>"
      elsif OBJECT_ID_KEYS.include?(parent_key.to_s) && value.match?(PARSE_OID_RE)
        "<<OBJECT_ID>>"
      else
        value
      end
    when Symbol
      value.to_s
    else
      value
    end
  end

  def self.path_for(group, name)
    File.join(SNAPSHOT_ROOT, group, "#{name}.json")
  end

  def self.serialize(obj)
    JSON.pretty_generate(normalize(obj))
  end

  module Assertions
    # Assert that the given object matches the stored snapshot.
    #
    # @param obj [Hash, Array] the compiled payload. Routed through
    #   JSON.parse(JSON.generate(obj)) first so as_json-style objects collapse
    #   to plain Hash/Array/scalars.
    # @param name [String] file-system-safe identifier within the group.
    # @param group [String] subdirectory under test/snapshots/.
    def assert_snapshot(obj, name:, group:)
      plain = JSON.parse(JSON.generate(obj))
      actual = SnapshotHelper.serialize(plain)
      path = SnapshotHelper.path_for(group, name)

      if SnapshotHelper.write?
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, actual + "\n")
        skip "snapshot updated: #{group}/#{name}"
        return
      end

      unless File.exist?(path)
        flunk "Snapshot fixture is missing: #{path}. " \
              "Re-run with UPDATE_SNAPSHOTS=1 to create it, then review " \
              "the generated file before committing."
      end

      expected = File.read(path).chomp
      assert_equal expected, actual,
                   "Snapshot mismatch for #{group}/#{name}. " \
                   "If the change is intentional, re-run with UPDATE_SNAPSHOTS=1."
    end
  end
end

Minitest::Test.include(SnapshotHelper::Assertions) if defined?(Minitest::Test)
