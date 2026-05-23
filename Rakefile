#!/usr/bin/env rake
require "bundler/gem_tasks"
require "yard"
require "rake/testtask"

# Several MCP/debug tasks need to run `Parse.setup(...)` against a
# local Parse instance. This helper preserves the local-stack
# convenience defaults while refusing to apply those defaults against
# anything that isn't a loopback URL — so a developer who pointed
# `PARSE_SERVER_URL` at a real Parse Server but forgot to set the
# secret env vars gets a loud abort instead of a silent boot with
# placeholder credentials.
#
# @return [Array(String, String, String, String)]
#   server_url, application_id, api_key, master_key
def mcp_credentials_or_abort!
  server_url   = ENV["PARSE_SERVER_URL"] || "http://localhost:2337/parse"
  app_id       = ENV["PARSE_APP_ID"]
  rest_api_key = ENV["PARSE_API_KEY"]
  master_key   = ENV["PARSE_MASTER_KEY"]

  is_local = server_url =~ %r{\Ahttps?://(?:localhost|127\.0\.0\.1|::1|\[::1\])(?::|/|\z)}

  if app_id.to_s.empty? || master_key.to_s.empty?
    if is_local
      app_id       = (app_id.to_s.empty? ? "myAppId" : app_id)
      rest_api_key = (rest_api_key.to_s.empty? ? "myApiKey" : rest_api_key)
      master_key   = (master_key.to_s.empty? ? "myMasterKey" : master_key)
    else
      abort "[Rakefile] PARSE_SERVER_URL=#{server_url} is not local; refusing to fall back to " \
            "placeholder credentials. Set PARSE_APP_ID and PARSE_MASTER_KEY explicitly."
    end
  end

  [server_url, app_id, rest_api_key, master_key]
end

# Default test task runs all tests with Docker enabled
Rake::TestTask.new do |t|
  ENV['PARSE_TEST_USE_DOCKER'] = 'true'
  t.libs << "lib/parse/stack"
  t.test_files = FileList["test/lib/**/*_test.rb"]
  t.warning = false
  t.verbose = true
end

# Integration tests require Docker
namespace :test do
  desc "Run all integration tests (requires Docker)"
  task :integration do
    integration_files = FileList["test/lib/**/*integration_test.rb"]
    
    puts "Running #{integration_files.length} integration test files..."
    integration_files.each_with_index do |file, index|
      puts "Running integration test #{index + 1}/#{integration_files.length}: #{file}"

      # 10: docker integration test fails for cloud functions
      skip_till = 0
      if (index + 1) <= skip_till
        puts "Skipping test #{index + 1} as per configuration\n"
        next
      end

      puts "\n" + "="*80
      puts "Running: #{file}"
      puts "="*80
      system("PARSE_TEST_USE_DOCKER=true ruby -Ilib:test #{file}") || exit(1)
    end
    puts "\n✅ All integration tests completed successfully!"
  end

  desc "Run unit tests only (no Docker required)"
  task :unit do
    unit_files = FileList["test/lib/**/*_test.rb"].exclude("test/lib/**/*integration_test.rb")
    
    puts "Running #{unit_files.length} unit test files (no Docker)..."
    unit_files.each_with_index do |file, index|
      puts "Running unit test #{index + 1}/#{unit_files.length}: #{file}"

      # 73 is problematic Testing Contains and Nin with Parse Objects with contains and nin 
      skip_till = 0
      if (index + 1) <= skip_till
        puts "Skipping test #{index + 1} as per configuration"
        next
      end

      system("PARSE_TEST_USE_DOCKER=true ruby -Ilib:test #{file}") || exit(1)
    end
    puts "\n✅ All unit tests completed successfully!"
  end

  desc "List all available test files"
  task :list do
    puts "\nIntegration Tests:"
    FileList["test/lib/**/*integration_test.rb"].each { |f| puts "  #{f}" }

    puts "\nUnit Tests:"
    FileList["test/lib/**/*_test.rb"].exclude("test/lib/**/*integration_test.rb").each { |f| puts "  #{f}" }
  end

  # ---------------------------------------------------------------------------
  # MCP protocol conformance via Anthropic's official mcp-inspector tool.
  #
  # Boots a local MCPServer against a configured Parse Server, then runs
  # @modelcontextprotocol/inspector in CLI mode to validate the MCP wire
  # protocol (initialize handshake, tools/list, tools/call, prompts/list,
  # resources/list, error envelopes). Catches protocol regressions that
  # in-process integration tests can miss because they exercise the Ruby
  # call surface, not the JSON wire format an external MCP client sees.
  #
  # Requirements:
  #   - npx on PATH (Node.js 18+)
  #   - A running Parse Server (e.g., `docker-compose -f scripts/docker/
  #     docker-compose.test.yml up -d`)
  #   - Env: PARSE_SERVER_URL, PARSE_APP_ID, PARSE_API_KEY (defaults match
  #     the Docker compose setup in scripts/docker/docker-compose.test.yml)
  #
  # Usage:
  #   rake test:mcp_inspector
  #   rake test:mcp_inspector METHOD=tools/list  # override target method
  # ---------------------------------------------------------------------------
  desc "Validate MCP protocol with Anthropic's mcp-inspector (requires npx)"
  task :mcp_inspector do
    require "net/http"
    require "uri"
    require "fileutils"

    unless system("which npx > /dev/null 2>&1")
      abort "[mcp_inspector] npx not found on PATH. Install Node.js 18+ or use `nvm use 18`."
    end

    port    = ENV["MCP_INSPECTOR_PORT"] || "3099"
    api_key = ENV["MCP_INSPECTOR_KEY"]  || "rake-inspector-key"
    method  = ENV["METHOD"]             || "tools/list"

    server_url, app_id, rest_api_key, master_key = mcp_credentials_or_abort!

    boot = <<~RUBY
      $LOAD_PATH.unshift(File.expand_path('lib'))
      require 'parse-stack'
      Parse.setup(
        server_url:     #{server_url.inspect},
        application_id: #{app_id.inspect},
        api_key:        #{rest_api_key.inspect},
        master_key:     #{master_key.inspect},
      )
      ENV['PARSE_MCP_ENABLED']    = 'true'
      Parse.mcp_server_enabled    = true
      Parse::Agent.mcp_enabled    = true
      require 'parse/agent/mcp_server'
      Parse::Agent::MCPServer.run(
        port:        #{port.to_i},
        host:        '127.0.0.1',
        permissions: :readonly,
        api_key:     #{api_key.inspect},
      )
    RUBY

    log_path = "tmp/mcp-inspector-server.log"
    FileUtils.mkdir_p("tmp")
    pid = Process.spawn("ruby", "-e", boot, out: log_path, err: log_path)

    begin
      ready = false
      40.times do
        sleep 0.25
        begin
          uri = URI("http://127.0.0.1:#{port}/health")
          ready = (Net::HTTP.get_response(uri).code == "200")
          break if ready
        rescue Errno::ECONNREFUSED, Errno::EADDRINUSE
          # retry
        end
      end
      unless ready
        warn "[mcp_inspector] MCPServer failed to become healthy on port #{port}. Server log:"
        warn(File.read(log_path)) rescue nil
        abort "[mcp_inspector] aborting"
      end
      puts "[mcp_inspector] MCPServer healthy on http://127.0.0.1:#{port}"

      cmd = [
        "npx", "--yes", "@modelcontextprotocol/inspector",
        "--cli", "http://127.0.0.1:#{port}/mcp",
        "--method", method,
        "--header", "X-MCP-API-Key:#{api_key}",
      ]
      puts "[mcp_inspector] $ #{cmd.join(" ")}"
      ok = system(*cmd)
      abort "[mcp_inspector] inspector exited non-zero" unless ok
      puts "[mcp_inspector] protocol check passed"
    ensure
      if pid
        Process.kill("TERM", pid) rescue nil
        Process.wait(pid)         rescue nil
      end
    end
  end
end

task :default => :test

task :console do
  exec "./bin/console"
end
task :c => :console

# ===========================================================================
# MCP namespace: interactive REPL and one-shot tool dispatch.
# ===========================================================================
namespace :mcp do
  # -------------------------------------------------------------------------
  # rake mcp:console
  #
  # Drops you into an IRB session with a pre-configured Parse::Agent and
  # MCP helpers bound at the top level. Talk to the agent the same way an
  # LLM would, but interactively from your terminal.
  #
  # Setup:
  #   - .env (or shell env) provides PARSE_SERVER_URL / PARSE_APP_ID /
  #     PARSE_API_KEY / PARSE_MASTER_KEY. Defaults match the Docker
  #     compose harness in scripts/docker/docker-compose.test.yml.
  #   - Optionally MCP_AGENT_PERMISSIONS=readonly|write|admin
  #     (default :readonly).
  #
  # Bindings available in the REPL:
  #   agent              — the Parse::Agent instance.
  #   tools              — print every tool the agent has access to.
  #   schemas            — print every visible class name.
  #   t(name, **kwargs)  — invoke a tool, return its result hash.
  #   q(class_name, ...) — shortcut for t(:query_class, class_name:, **opts).
  #   count(class_name)  — shortcut for t(:count_objects, class_name:, ...).
  #   schema(class_name) — shortcut for t(:get_schema, class_name:).
  #   dispatch(method, params={}) — call MCPDispatcher.call(body:, agent:).
  #   prompts            — print every registered + builtin prompt.
  #   render_prompt(name, args={}) — render a prompt to its message envelope.
  #
  # Example session:
  #   $ bundle exec rake mcp:console
  #   irb> tools
  #   irb> q("MCPSchoolTeacher", limit: 3)
  #   irb> count("MCPSchoolStudent")
  #   irb> dispatch("initialize")
  # -------------------------------------------------------------------------
  desc "Interactive MCP REPL: query a Parse::Agent like an LLM would, but with Ruby"
  task :console do
    require "irb"
    require "json"
    # dotenv is in the Gemfile :test, :development group; load .env if present.
    begin
      require "dotenv/load"
    rescue LoadError
      # dotenv not installed; rely on shell env vars
    end

    $LOAD_PATH.unshift(File.expand_path("lib", __dir__))
    require "parse-stack"
    require "parse/agent"
    require "parse/agent/mcp_dispatcher"
    require "parse/agent/prompts"
    require "parse/agent/mcp_client"

    server_url, app_id, rest_api_key, master_key = mcp_credentials_or_abort!
    permissions  = (ENV["MCP_AGENT_PERMISSIONS"] || "readonly").to_sym

    Parse.setup(
      server_url:     server_url,
      application_id: app_id,
      api_key:        rest_api_key,
      master_key:     master_key,
    )

    agent = Parse::Agent.new(permissions: permissions)

    # Bind helpers as singleton methods on TOPLEVEL_BINDING so they're
    # callable bare in the IRB session without a receiver.
    Object.send(:define_method, :agent) { agent }
    Object.send(:define_method, :_mcp_agent_const) { agent }

    Object.send(:define_method, :tools) do
      list = agent.tool_definitions(format: :mcp).map { |t| t[:name] || t["name"] }
      puts list.sort.join("\n")
      list.size
    end

    Object.send(:define_method, :schemas) do
      result = agent.execute(:get_all_schemas)
      unless result[:success]
        puts "get_all_schemas failed: #{result[:error]}"
        next nil
      end
      custom   = (result[:data][:custom]   || []).map { |c| c[:name] }
      built_in = (result[:data][:built_in] || []).map { |c| c[:name] }
      puts "Custom:   #{custom.sort.join(", ")}"
      puts "Built-in: #{built_in.sort.join(", ")}"
      custom + built_in
    end

    Object.send(:define_method, :t) do |name, **kwargs|
      agent.execute(name.to_sym, **kwargs)
    end

    Object.send(:define_method, :q) do |class_name, **opts|
      t(:query_class, class_name: class_name, **opts)
    end

    Object.send(:define_method, :count) do |class_name, **opts|
      t(:count_objects, class_name: class_name, **opts)
    end

    Object.send(:define_method, :schema) do |class_name|
      t(:get_schema, class_name: class_name)
    end

    Object.send(:define_method, :dispatch) do |method, params = {}|
      body = { "jsonrpc" => "2.0", "id" => SecureRandom.hex(4), "method" => method.to_s, "params" => params }
      Parse::Agent::MCPDispatcher.call(body: body, agent: agent)
    end

    Object.send(:define_method, :prompts) do
      list = Parse::Agent::Prompts.list.map { |p| p["name"] }
      puts list.sort.join("\n")
      list.size
    end

    Object.send(:define_method, :render_prompt) do |name, args = {}|
      Parse::Agent::Prompts.render(name.to_s, args.transform_keys(&:to_s))
    end

    # When LLM_PROVIDER + LLM_API_KEY are in env (e.g. via .env), bind
    # `mcp` as a conversational client. Lets you do:
    #   mcp.ask("how many students?")
    #   _.reply("just for Ms. Vasquez")
    mcp = nil
    if ENV["LLM_PROVIDER"]
      begin
        mcp = Parse::Agent::MCPClient.new(agent: agent)
        Object.send(:define_method, :mcp) { mcp }
      rescue ArgumentError => e
        puts "[mcp:console] could not initialize MCPClient — #{e.message}"
        puts "[mcp:console]   set LLM_PROVIDER + LLM_API_KEY in your .env (see .env.sample)"
      end
    end

    puts "=" * 70
    puts "Parse::Agent MCP Console"
    puts "=" * 70
    puts "Server:      #{server_url}"
    puts "Permissions: #{permissions}"
    puts "Agent:       #{agent.class.name} (#{agent.allowed_tools.size} tools)"
    puts "LLM client:  " + (mcp ? "#{mcp.provider} / #{mcp.model}" : "DISABLED (set LLM_PROVIDER + LLM_API_KEY to enable mcp.ask)")
    puts
    puts "Try:"
    if mcp
      puts "  mcp.ask('how many students do we have?')"
      puts "  _.reply('what about just for Ms. Vasquez?')      # chain replies"
      puts
    end
    puts "  tools                         # list available tools"
    puts "  schemas                       # list visible Parse classes"
    puts "  q('User', limit: 3)           # query_class shortcut"
    puts "  count('Song')                 # count_objects shortcut"
    puts "  schema('Song')                # get_schema shortcut"
    puts "  t(:query_class, class_name: 'Song', where: { name: 'X' })"
    puts "  dispatch('tools/list')        # MCPDispatcher round-trip"
    puts "  prompts                       # list registered prompts"
    puts "  render_prompt('parse_conventions')"
    puts "=" * 70

    IRB.start
  end

  # -------------------------------------------------------------------------
  # rake mcp:chat
  #
  # Conversational CLI loop — talk to your Parse database via the MCP agent
  # in plain English. Each turn drives the LLM through tool calls and prints
  # the final answer; context persists across turns. Like a tiny REPL just
  # for the MCP agent.
  #
  # Setup:
  #   - .env (or shell env) with LLM_PROVIDER + LLM_API_KEY (see .env.sample)
  #   - PARSE_SERVER_URL / PARSE_APP_ID / PARSE_API_KEY / PARSE_MASTER_KEY
  #     (defaults match the Docker compose harness)
  #
  # Slash commands inside the loop:
  #   /reset   — start a fresh conversation (clear history)
  #   /compact — replace history with an LLM-generated summary (1 extra call)
  #   /tools   — list available MCP tools
  #   /trace   — toggle tool-call tracing on/off
  #   /cost    — show running token + USD cost totals
  #   /history — print conversation history
  #   /exit    — leave the chat (also: /quit, exit, quit, Ctrl-D, empty line)
  # -------------------------------------------------------------------------
  desc "Conversational CLI: talk to your Parse data via the MCP agent"
  task :chat do
    begin
      require "dotenv/load"
    rescue LoadError
    end

    $LOAD_PATH.unshift(File.expand_path("lib", __dir__))
    require "parse-stack"
    require "parse/agent"
    require "parse/agent/mcp_client"

    unless ENV["LLM_PROVIDER"]
      abort "[mcp:chat] LLM_PROVIDER is not set. Add it to .env (see .env.sample). " \
            "Supported providers: openai, anthropic, lmstudio."
    end

    server_url, app_id, rest_api_key, master_key = mcp_credentials_or_abort!
    Parse.setup(
      server_url:     server_url,
      application_id: app_id,
      api_key:        rest_api_key,
      master_key:     master_key,
    )

    permissions = (ENV["MCP_AGENT_PERMISSIONS"] || "readonly").to_sym
    agent = Parse::Agent.new(permissions: permissions)
    client = Parse::Agent::MCPClient.new(agent: agent)
    trace = (ENV["MCP_CHAT_TRACE"] || "false") == "true"

    slash_help = lambda do
      puts "Slash commands:"
      puts "  /help    — print this list"
      puts "  /reset   — clear conversation history"
      puts "  /compact — replace history with an LLM-generated summary"
      puts "  /tools   — list MCP tools the agent has access to"
      puts "  /trace   — toggle per-turn tool-call tracing on/off"
      puts "  /cost    — show running token + USD totals (and last turn)"
      puts "  /history — print the conversation log"
      puts "  /exit    — leave (also /quit, exit, quit, Ctrl-D, empty line)"
    end

    puts "=" * 70
    puts "Parse MCP Chat — #{client.provider} / #{client.model}"
    puts "Permissions: #{permissions}  |  Trace: #{trace ? "on" : "off"}"
    puts "Type your question. Type /help for slash commands."
    puts "=" * 70

    loop do
      print "\n> "
      line = $stdin.gets
      break if line.nil?  # Ctrl-D
      line = line.strip
      next if line.empty?

      case line
      when "/exit", "/quit", "exit", "quit"
        break
      when "/help"
        slash_help.call
        next
      when "/reset"
        client.reset!
        puts "[conversation cleared]"
        next
      when "/compact"
        before = client.usage.total_tokens
        summary = client.compact!
        if summary.empty?
          puts "[nothing to compact]"
        else
          delta = client.usage.total_tokens - before
          puts "[compacted; +#{delta} tokens spent on summary]"
          puts "  summary: #{summary[0, 200]}#{summary.length > 200 ? "…" : ""}"
        end
        next
      when "/tools"
        puts agent.tool_definitions(format: :mcp).map { |t| t[:name] || t["name"] }.sort.join("\n")
        next
      when "/trace"
        trace = !trace
        puts "[trace #{trace ? "on" : "off"}]"
        next
      when "/cost"
        u = client.usage
        last = client.last_call_usage
        printf "  session: %d in + %d out = %d tokens   $%.4f\n",
               u.prompt_tokens, u.completion_tokens, u.total_tokens, u.cost_usd
        if last
          printf "  last:    %d in + %d out = %d tokens   $%.6f\n",
                 last.prompt_tokens, last.completion_tokens, last.total_tokens, last.cost_usd
        end
        next
      when "/history"
        client.history.each_with_index do |m, i|
          puts "  #{i + 1}. [#{m[:role]}] #{m[:content].to_s[0, 120]}"
        end
        next
      end

      begin
        result = client.ask(line, reset: false)
        if trace && result.tool_calls.any?
          puts "─── tool calls ───"
          result.tool_calls.each_with_index do |tc, i|
            args = tc[:arguments].is_a?(Hash) ? tc[:arguments].inspect : tc[:arguments].to_s
            puts "  #{i + 1}. #{tc[:name]}(#{args})"
          end
        end
        puts
        puts result.text.to_s.empty? ? "[empty response]" : result.text
        if trace && result.usage && result.usage.total_tokens.positive?
          printf "[%d tokens / $%.6f this turn   session: %d / $%.4f]\n",
                 result.usage.total_tokens, result.usage.cost_usd,
                 client.usage.total_tokens, client.usage.cost_usd
        end
      rescue Interrupt
        puts "\n[interrupted]"
        next
      rescue => e
        puts "[error] #{e.class}: #{e.message}"
      end
    end

    puts "\nbye"
  end

  # -------------------------------------------------------------------------
  # rake "mcp:tool[query_class,{\"class_name\":\"Song\",\"limit\":3}]"
  #
  # One-shot tool dispatch from the command line. The first arg is the tool
  # name; the second is a JSON object of keyword arguments. Result printed
  # as pretty JSON. Useful for ad-hoc smoke checks without spinning up IRB.
  # -------------------------------------------------------------------------
  desc "One-shot tool call: rake 'mcp:tool[name,jsonArgs]'"
  task :tool, [:name, :args_json] do |_t, args|
    begin
      require "dotenv/load"
    rescue LoadError
    end
    require "json"
    require "parse-stack"
    require "parse/agent"

    tool_name = (args[:name] || abort("usage: rake 'mcp:tool[name,jsonArgs]'")).to_sym
    raw       = args[:args_json] || "{}"
    parsed    = JSON.parse(raw)
    kwargs    = parsed.transform_keys(&:to_sym)

    server_url, app_id, rest_api_key, master_key = mcp_credentials_or_abort!
    Parse.setup(
      server_url:     server_url,
      application_id: app_id,
      api_key:        rest_api_key,
      master_key:     master_key,
    )

    agent = Parse::Agent.new(permissions: (ENV["MCP_AGENT_PERMISSIONS"] || "readonly").to_sym)
    result = agent.execute(tool_name, **kwargs)
    puts JSON.pretty_generate(result)
    exit(result[:success] ? 0 : 1)
  end
end

desc "List undocumented methods"
task "yard:stats" do
  exec "yard stats --list-undoc"
end

desc "Start the yard server"
task "docs" do
  exec "rm -rf ./yard && yard server --reload"
end

YARD::Rake::YardocTask.new do |t|
  t.files = ["lib/**/*.rb"]   # optional
  t.options = ["-o", "doc/parse-stack-next"] # optional
  t.stats_options = ["--list-undoc"]         # optional
end
