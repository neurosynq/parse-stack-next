# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/mongodb"

# Unit tests for Parse::MongoDB's Atlas Search index mutation primitives:
# create_search_index, drop_search_index, update_search_index, plus the
# writer_search_indexes existence-check helper. All stubbed — no live
# Mongo or Atlas needed.
class MongoDBSearchIndexesTest < Minitest::Test
  def setup
    @stash_analytics = ENV.delete("ANALYTICS_DATABASE_URI")
    @stash_database  = ENV.delete("DATABASE_URI")
    @stash_mutations = ENV.delete(Parse::MongoDB::MUTATION_ENV_KEY)
    Parse::MongoDB.reset!
  end

  def teardown
    ENV["ANALYTICS_DATABASE_URI"] = @stash_analytics if @stash_analytics
    ENV["DATABASE_URI"]           = @stash_database  if @stash_database
    if @stash_mutations
      ENV[Parse::MongoDB::MUTATION_ENV_KEY] = @stash_mutations
    else
      ENV.delete(Parse::MongoDB::MUTATION_ENV_KEY)
    end
    Parse::MongoDB.reset!
  end

  # ---- helpers -----------------------------------------------------------

  # Fully configure both reader and writer, enable all three gates, and
  # install a capturing fake writer client. Returns the captured-command
  # array — every database.command(...) call appends one entry.
  def configure_writer_with_capture(existing_indexes: [])
    Parse::MongoDB.configure(
      uri: "mongodb://stub-reader:27017/db",
      enabled: true,
      verify_role: false,
    )
    Parse::MongoDB.configure_writer(
      uri: "mongodb://stub-writer:27017/db",
      enabled: true,
      verify_role: false,
    )
    Parse::MongoDB.index_mutations_enabled = true
    ENV[Parse::MongoDB::MUTATION_ENV_KEY] = "1"

    captured = []
    Parse::MongoDB.instance_variable_set(:@writer_client, fake_writer_client(captured, existing_indexes))
    captured
  end

  # Build a fake writer client that:
  #  - responds to [coll] with a fake collection whose .aggregate([...])
  #    returns the supplied existing_indexes (for writer_search_indexes)
  #  - exposes .database.command(*args) which appends args to `captured`
  #    and returns a no-op response
  def fake_writer_client(captured, existing_indexes)
    fake_agg = Object.new
    fake_agg.define_singleton_method(:to_a) { existing_indexes }

    fake_coll = Object.new
    fake_coll.define_singleton_method(:aggregate) { |_pipeline| fake_agg }

    fake_db = Object.new
    fake_db.define_singleton_method(:command) do |*args|
      captured << args
      [{ "ok" => 1 }]
    end

    fake_client = Object.new
    fake_client.define_singleton_method(:[]) { |_coll| fake_coll }
    fake_client.define_singleton_method(:database) { fake_db }
    fake_client.define_singleton_method(:close) { nil }
    fake_client
  end

  # Silence audit warnings while a block runs. Audit lines go to STDERR
  # via Kernel#warn — we don't want them polluting test output, but the
  # default Minitest Reporter suppresses STDERR per-test, so this is
  # belt-and-braces for noisy local runs.
  def silence_warnings
    old = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = old
  end

  # ---- WRITER_ALLOWED_ACTIONS -------------------------------------------

  def test_writer_allowed_actions_includes_new_search_index_actions
    %w[createSearchIndexes dropSearchIndex updateSearchIndex listSearchIndexes].each do |action|
      assert_includes Parse::MongoDB::WRITER_ALLOWED_ACTIONS, action,
                      "WRITER_ALLOWED_ACTIONS must include #{action} so a writer role " \
                      "provisioned with it passes the configure_writer privilege probe."
    end
  end

  def test_writer_allowed_actions_does_not_include_destructive_actions
    %w[insert update remove dropCollection dropDatabase].each do |action|
      refute_includes Parse::MongoDB::WRITER_ALLOWED_ACTIONS, action
    end
  end

  # ---- gate enforcement --------------------------------------------------

  def test_create_search_index_raises_writer_not_configured_when_writer_absent
    assert_raises(Parse::MongoDB::WriterNotConfigured) do
      Parse::MongoDB.create_search_index("Song", "song_search", { mappings: { dynamic: true } })
    end
  end

  def test_create_search_index_raises_mutations_disabled_when_flag_off
    Parse::MongoDB.configure(uri: "mongodb://stub-reader:27017/db", enabled: true, verify_role: false)
    Parse::MongoDB.configure_writer(uri: "mongodb://stub-writer:27017/db", enabled: true, verify_role: false)
    Parse::MongoDB.index_mutations_enabled = false
    ENV[Parse::MongoDB::MUTATION_ENV_KEY] = "1"

    assert_raises(Parse::MongoDB::MutationsDisabled) do
      Parse::MongoDB.create_search_index("Song", "song_search", { mappings: { dynamic: true } })
    end
  end

  def test_create_search_index_raises_mutations_disabled_when_env_unset
    Parse::MongoDB.configure(uri: "mongodb://stub-reader:27017/db", enabled: true, verify_role: false)
    Parse::MongoDB.configure_writer(uri: "mongodb://stub-writer:27017/db", enabled: true, verify_role: false)
    Parse::MongoDB.index_mutations_enabled = true
    ENV.delete(Parse::MongoDB::MUTATION_ENV_KEY)

    assert_raises(Parse::MongoDB::MutationsDisabled) do
      Parse::MongoDB.create_search_index("Song", "song_search", { mappings: { dynamic: true } })
    end
  end

  def test_create_search_index_refuses_parse_internal_collection_without_optin
    configure_writer_with_capture
    assert_raises(Parse::MongoDB::ForbiddenCollection) do
      Parse::MongoDB.create_search_index("_User", "u_search", { mappings: { dynamic: true } })
    end
  end

  def test_create_search_index_allows_parse_internal_with_explicit_optin
    captured = configure_writer_with_capture
    result = silence_warnings do
      Parse::MongoDB.create_search_index("_User", "u_search",
                                          { mappings: { dynamic: true } },
                                          allow_system_classes: true)
    end
    assert_equal :created, result
    assert_equal 1, captured.size
  end

  # ---- input validation --------------------------------------------------

  def test_create_search_index_rejects_invalid_name
    configure_writer_with_capture
    %w[
      1leading_digit has\ space has/slash has:colon has.dot
    ].each do |bad|
      assert_raises(ArgumentError, "expected #{bad.inspect} to be rejected") do
        Parse::MongoDB.create_search_index("Song", bad, { mappings: { dynamic: true } })
      end
    end
  end

  def test_create_search_index_rejects_empty_or_overlong_name
    configure_writer_with_capture
    assert_raises(ArgumentError) do
      Parse::MongoDB.create_search_index("Song", "", { mappings: { dynamic: true } })
    end
    too_long = "a" + ("x" * 64)  # 65 chars, exceeds the 64-char ceiling
    assert_raises(ArgumentError) do
      Parse::MongoDB.create_search_index("Song", too_long, { mappings: { dynamic: true } })
    end
  end

  def test_create_search_index_accepts_max_length_name
    captured = configure_writer_with_capture
    max_name = "a" + ("x" * 63)  # 64 chars total
    silence_warnings do
      Parse::MongoDB.create_search_index("Song", max_name, { mappings: { dynamic: true } })
    end
    assert_equal 1, captured.size
  end

  def test_create_search_index_rejects_non_hash_or_empty_definition
    configure_writer_with_capture
    assert_raises(ArgumentError) do
      Parse::MongoDB.create_search_index("Song", "ix", nil)
    end
    assert_raises(ArgumentError) do
      Parse::MongoDB.create_search_index("Song", "ix", {})
    end
    assert_raises(ArgumentError) do
      Parse::MongoDB.create_search_index("Song", "ix", "not a hash")
    end
  end

  # ---- create_search_index command shape --------------------------------

  def test_create_search_index_issues_create_command_with_string_keyed_definition
    captured = configure_writer_with_capture
    silence_warnings do
      Parse::MongoDB.create_search_index(
        "Song", "song_search",
        { mappings: { dynamic: false, fields: { title: { type: "string" } } } },
      )
    end
    assert_equal 1, captured.size
    cmd = captured.first.first
    assert_equal "Song", cmd[:createSearchIndexes]
    assert_kind_of Array, cmd[:indexes]
    entry = cmd[:indexes].first
    assert_equal "song_search", entry[:name]
    # stringify_keys_deep must convert nested symbol keys to strings.
    assert_equal({ "mappings" => { "dynamic" => false, "fields" => { "title" => { "type" => "string" } } } },
                 entry[:definition])
  end

  def test_create_search_index_returns_exists_when_name_already_present
    captured = configure_writer_with_capture(existing_indexes: [{ "name" => "song_search", "queryable" => true }])
    result = silence_warnings do
      Parse::MongoDB.create_search_index("Song", "song_search", { mappings: { dynamic: true } })
    end
    assert_equal :exists, result
    assert_empty captured, "create command must not be issued when an index with the name exists"
  end

  def test_create_search_index_returns_created_when_no_collision
    captured = configure_writer_with_capture(existing_indexes: [{ "name" => "other_index" }])
    result = silence_warnings do
      Parse::MongoDB.create_search_index("Song", "song_search", { mappings: { dynamic: true } })
    end
    assert_equal :created, result
    assert_equal 1, captured.size
  end

  # ---- drop_search_index --------------------------------------------------

  def test_drop_search_index_requires_search_prefixed_confirm_token
    configure_writer_with_capture(existing_indexes: [{ "name" => "song_search" }])
    # The regular-index token must NOT be accepted for a search-index drop.
    assert_raises(ArgumentError) do
      Parse::MongoDB.drop_search_index("Song", "song_search", confirm: "drop:Song:song_search")
    end
    # An empty or wrong token also rejected.
    assert_raises(ArgumentError) do
      Parse::MongoDB.drop_search_index("Song", "song_search", confirm: "wrong")
    end
  end

  def test_drop_search_index_returns_dropped_with_correct_confirm
    captured = configure_writer_with_capture(existing_indexes: [{ "name" => "song_search" }])
    result = silence_warnings do
      Parse::MongoDB.drop_search_index("Song", "song_search",
                                       confirm: "drop_search:Song:song_search")
    end
    assert_equal :dropped, result
    assert_equal 1, captured.size
    cmd = captured.first.first
    assert_equal "Song", cmd[:dropSearchIndex]
    assert_equal "song_search", cmd[:name]
  end

  def test_drop_search_index_returns_absent_when_index_missing
    captured = configure_writer_with_capture(existing_indexes: [])
    result = silence_warnings do
      Parse::MongoDB.drop_search_index("Song", "no_such",
                                       confirm: "drop_search:Song:no_such")
    end
    assert_equal :absent, result
    assert_empty captured, "drop command must not be issued when the index doesn't exist"
  end

  # ---- update_search_index ------------------------------------------------

  def test_update_search_index_raises_when_index_missing
    configure_writer_with_capture(existing_indexes: [])
    assert_raises(ArgumentError) do
      silence_warnings do
        Parse::MongoDB.update_search_index("Song", "no_such", { mappings: { dynamic: true } })
      end
    end
  end

  def test_update_search_index_emits_absent_audit_before_raising
    configure_writer_with_capture(existing_indexes: [])
    captured_warnings = []
    Parse::MongoDB.singleton_class.send(:alias_method, :__test_orig_warn, :warn) if Parse::MongoDB.respond_to?(:warn)
    Parse::MongoDB.define_singleton_method(:warn) { |msg| captured_warnings << msg }
    # Also intercept Kernel#warn on the module's audit path: audit_writer_event
    # is a private method on Parse::MongoDB's singleton that calls Kernel#warn.
    # We capture by stubbing the Kernel.warn-equivalent on the singleton.
    begin
      Parse::MongoDB.singleton_class.class_eval do
        define_method(:warn) { |msg| captured_warnings << msg }
      end
      assert_raises(ArgumentError) do
        Parse::MongoDB.update_search_index("Song", "missing", { mappings: { dynamic: true } })
      end
      assert captured_warnings.any? { |w| w.to_s.include?("update_search_index_absent") },
             "expected an update_search_index_absent audit line; got: #{captured_warnings.inspect}"
    ensure
      Parse::MongoDB.singleton_class.send(:remove_method, :warn) rescue nil
    end
  end

  def test_update_search_index_issues_update_command_when_index_exists
    captured = configure_writer_with_capture(existing_indexes: [{ "name" => "song_search" }])
    result = silence_warnings do
      Parse::MongoDB.update_search_index("Song", "song_search",
                                         { mappings: { dynamic: false, fields: { title: { type: "string" } } } })
    end
    assert_equal :updated, result
    assert_equal 1, captured.size
    cmd = captured.first.first
    assert_equal "Song", cmd[:updateSearchIndex]
    assert_equal "song_search", cmd[:name]
    assert_equal({ "mappings" => { "dynamic" => false, "fields" => { "title" => { "type" => "string" } } } },
                 cmd[:definition])
  end

  # ---- writer_search_indexes ---------------------------------------------

  def test_writer_search_indexes_raises_when_writer_unconfigured
    assert_raises(Parse::MongoDB::WriterNotConfigured) do
      Parse::MongoDB.writer_search_indexes("Song")
    end
  end

  def test_writer_search_indexes_returns_existing_indexes
    configure_writer_with_capture(existing_indexes: [{ "name" => "a" }, { "name" => "b" }])
    out = Parse::MongoDB.writer_search_indexes("Song")
    assert_equal %w[a b], out.map { |i| i["name"] }
  end

  def test_writer_search_indexes_refuses_internal_collection_without_optin
    configure_writer_with_capture
    assert_raises(Parse::MongoDB::ForbiddenCollection) do
      Parse::MongoDB.writer_search_indexes("_User")
    end
  end
end
