require_relative "../../test_helper"
require "open3"
require "rbconfig"

# Host-application compatibility checks that depend on load order, so each
# one runs in a fresh Ruby process.
class HostCompatLoadTest < Minitest::Test
  LIB = File.expand_path("../../../lib", __dir__)

  def run_ruby(script)
    out, status = Open3.capture2e(RbConfig.ruby, "-I#{LIB}", "-e", script)
    [out, status]
  end

  # rails-html-sanitizer (and others) define a bare `Rails` module without
  # railties. Loading the gem must not try to subclass Rails::Railtie.
  def test_loads_with_bare_rails_module
    out, status = run_ruby(<<~RUBY)
      module Rails; end
      require "parse-stack-next"
      puts defined?(Parse::Stack::Railtie).inspect
    RUBY
    assert status.success?, out
    assert_includes out, "nil"
  end

  def test_installs_railtie_when_railties_is_loaded
    out, status = run_ruby(<<~RUBY)
      module Rails
        class Railtie
          def self.rake_tasks(*); end
          def self.generators(*); end
        end
      end
      require "parse-stack-next"
      puts (Parse::Stack::Railtie < Rails::Railtie).inspect
    RUBY
    assert status.success?, out
    assert_includes out, "true"
  end

  def test_rake_tasks_install_with_bare_rails_module
    out, status = run_ruby(<<~RUBY)
      module Rails; end
      require "parse-stack-next"
      require "parse/stack/tasks"
      Parse::Stack.load_tasks
      puts Rake::Task.task_defined?("parse:env")
    RUBY
    assert status.success?, out
    assert_includes out, "true"
  end

  # A library that defines its own Symbol methods first (Mongoid, Sequel
  # core extensions) keeps them; Parse records the conflict instead.
  def test_foreign_symbol_methods_are_not_replaced
    out, status = run_ruby(<<~RUBY)
      class Symbol
        def gt(*) = :foreign_gt
        def desc = :foreign_desc
      end
      require "parse-stack-next"
      p [:a.gt, :a.desc, Parse::Operation.symbol_conflicts.include?(:gt)]
      p :a.lt(3).class
    RUBY
    assert status.success?, out
    assert_includes out, "[:foreign_gt, :foreign_desc, true]"
    assert_includes out, "Parse::Constraint::LessThanConstraint"
  end

  # A Symbol method another library adds after Parse wins too, since Parse's
  # DSL lives in an included module rather than on Symbol itself.
  def test_symbol_methods_defined_after_parse_take_precedence
    out, status = run_ruby(<<~RUBY)
      require "parse-stack-next"
      class Symbol
        def gt(*) = :later_gt
      end
      p :a.gt
    RUBY
    assert status.success?, out
    assert_includes out, ":later_gt"
  end

  # When Mongoid owns Symbol#gt, its query keys still work in Parse queries.
  def test_mongoid_query_keys_translate_to_parse_operations
    out, status = run_ruby(<<~RUBY)
      module Mongoid; module Criteria; module Queryable
        class Key
          attr_reader :name, :operator
          def initialize(name, operator) = (@name, @operator = name, operator)
        end
      end; end; end
      class Symbol
        def gt = Mongoid::Criteria::Queryable::Key.new(self, "$gt")
        def desc = Mongoid::Criteria::Queryable::Key.new(self, -1)
      end
      require "parse-stack-next"
      class Song < Parse::Object; property :plays, :integer; end
      puts Song.query(:plays.gt => 10).compile_where.to_json
      p Parse::Order.from_foreign(:plays.desc).to_s
    RUBY
    assert status.success?, out
    assert_includes out, '{"plays":{"$gt":10}}'
    assert_includes out, '"-plays"'
  end

  # Atlas Search is loaded lazily; paths that reference it must load it
  # rather than raise NameError, even though protected_paths.rb defines the
  # Parse::AtlasSearch namespace early.
  def test_search_index_migrator_loads_atlas_search
    out, status = run_ruby(<<~RUBY)
      require "parse-stack-next"
      require "parse/atlas_search/protected_paths"
      Parse.setup(server_url: "http://localhost:1/parse", app_id: "x", master_key: "m")
      class Song < Parse::Object
        property :title
        mongo_search_index "song_text", { mappings: { dynamic: false, fields: { title: { type: "string" } } } }
      end
      Parse::MongoDB.define_singleton_method(:enabled?) { true }
      Song.search_indexes_plan
      puts defined?(Parse::AtlasSearch::IndexManager).inspect
      begin
        Song.apply_search_indexes!
      rescue NameError => e
        puts "NAMEERROR \#{e.message}"
      rescue StandardError => e
        puts "domain error \#{e.class}"
      end
    RUBY
    assert status.success?, out
    refute_includes out, "NAMEERROR"
    assert_includes out, '"constant"'
  end

  def test_describe_atlas_loads_atlas_search
    out, status = run_ruby(<<~RUBY)
      require "parse-stack-next"
      Parse.setup(server_url: "http://localhost:1/parse", app_id: "x", master_key: "m")
      class Song < Parse::Object; property :title; end
      Parse::MongoDB.define_singleton_method(:enabled?) { true }
      p Song.describe(:atlas, network: true)[:atlas][:error]
    RUBY
    assert status.success?, out
    refute_includes out, "NameError"
  end

  def test_agent_atlas_tool_loads_atlas_search
    out, status = run_ruby(<<~RUBY)
      require "parse-stack-next"
      Parse.setup(server_url: "http://localhost:1/parse", app_id: "x", master_key: "m")
      begin
        Parse::Agent::Tools.send(:invoke_atlas_search, :search, "Song", "hi", {})
      rescue Exception => e
        puts e.class
      end
    RUBY
    assert status.success?, out
    assert_includes out, "Parse::Agent::ValidationError"
  end

  # WEBrick is not a gem dependency. enable_mcp! must still work (the Rack
  # app does not need it) and only MCPServer#start explains what is missing.
  def test_enable_mcp_without_webrick
    out, status = run_ruby(<<~RUBY)
      module Kernel
        alias_method :__host_compat_require, :require
        def require(name)
          raise LoadError, "cannot load such file -- webrick" if name == "webrick"
          __host_compat_require(name)
        end
      end
      ENV["PARSE_MCP_ENABLED"] = "true"
      require "parse-stack-next"
      Parse.mcp_server_enabled = true
      server = Parse::Agent.enable_mcp!(port: 3999)
      p Parse::Agent.mcp_enabled?
      begin
        server.require_webrick!
      rescue LoadError => e
        puts e.message
      end
    RUBY
    assert status.success?, out
    assert_includes out, "true"
    assert_includes out, 'Add `gem "webrick"` to your Gemfile'
  end

  # Marker scrubbing must not depend on MCPClient having been loaded.
  def test_prompt_marker_scrubbing_without_mcp_client
    out, status = run_ruby(<<~RUBY)
      require "parse-stack-next"
      puts defined?(Parse::Agent::MCPClient).inspect
      marker = Parse::Agent::PromptHardening::UNTRUSTED_TOOL_RESULT_MARKER
      puts Parse::Agent::PromptHardening.send(:injection_markers).include?(marker)
    RUBY
    assert status.success?, out
    assert_includes out, "nil"
    assert_includes out, "true"
  end
end
