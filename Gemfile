source "https://rubygems.org"

# Specify your gem's dependencies in parse-stack-next.gemspec
gemspec name: "parse-stack-next"

group :test, :development do
  gem "dotenv"
  gem "redis"
  gem "rake"
  gem "debug", ">= 1.0"
  gem "minitest"
  gem "minitest-mock"
  gem 'minitest-reporters'
  gem "pry"
  gem "yard", ">= 0.9.11"
  gem "redcarpet"
  gem "rufo"
  gem "mongo"
  gem "webrick"
  # MCP integration test infrastructure (v4.1.0+).
  # puma:       streaming Rack server, exercises SSE worker thread under realistic
  #             flush semantics that WEBrick can't reproduce.
  # sinatra:    minimal classic-Rack mount target for verifying the
  #             Parse::Agent.rack_app embedding pattern.
  # rack-test:  drives Sinatra/Rack envs without an HTTP socket.
  gem "puma"
  gem "sinatra"
  gem "rack-test"
  # gem "thin" # for yard server - disabled due to eventmachine compilation issues
end
