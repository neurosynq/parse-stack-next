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
  # bundler-audit: scans Gemfile.lock against the ruby-advisory-db for known
  # CVEs. Used by the upstream-watch skill and dependency review.
  gem "bundler-audit", ">= 0.9"
  gem "yard", ">= 0.9.11"
  # Rack 3 removed Rack::Server (used by `yard server`); the rackup gem
  # restores it. Drop this once YARD's server adapter stops referencing it.
  gem "rackup"
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
  # MFA / TOTP test infrastructure (Parse::MFA, two_factor_auth).
  # rotp:    generates TOTP secrets and time-based codes so the MFA unit and
  #          integration tests can enroll and log in against Parse Server's
  #          TOTP adapter (SHA1 / 6 digits / 30s — rotp's defaults match).
  # rqrcode: renders the provisioning QR code exercised by Parse::MFA.qr_code.
  gem "rotp"
  gem "rqrcode"
  # gem "thin" # for yard server - disabled due to eventmachine compilation issues
end
