# coding: utf-8
lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "parse/stack/version"

Gem::Specification.new do |spec|
  spec.name = "parse-stack-next"
  spec.version = Parse::Stack::VERSION
  spec.authors =  ["Adrian Curtin", "Anthony Persaud", "Henry Spindell"]
  spec.email = ["adrian+parse-stack@neurosynq.net"]

  spec.summary = %q{Parse Server SDK for Ruby — ORM, queries, auth, and MongoDB-direct access}
  spec.description = %q{Production-grade Ruby client for Parse Server. Map Parse classes to Ruby models with typed properties, associations, and validations; build queries with a chainable DataMapper-style DSL; handle auth, sessions, MFA, cloud code webhooks, and push; introspect and migrate schemas; manage role hierarchies; scope access with per-agent ACL/CLP; generate GraphQL types; run Atlas Search and vector search; and bypass REST for high-throughput reads via the MongoDB-direct pipeline.}
  spec.homepage = "https://github.com/neurosynq/parse-stack-next"
  spec.license = "MIT"

  spec.metadata = {
    "homepage_uri"          => "https://github.com/neurosynq/parse-stack-next",
    "source_code_uri"       => "https://github.com/neurosynq/parse-stack-next",
    "changelog_uri"         => "https://github.com/neurosynq/parse-stack-next/blob/main/CHANGELOG.md",
    "bug_tracker_uri"       => "https://github.com/neurosynq/parse-stack-next/issues",
    "documentation_uri"     => "https://neurosynq.github.io/parse-stack-next/",
    "rubygems_mfa_required" => "true",
  }

  spec.files = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.bindir = "bin"
  spec.executables = ["parse-console"] #spec.files.grep(%r{^bin/pstack/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 3.2"

  spec.add_runtime_dependency "activemodel", [">= 6.1", "< 9"]
  spec.add_runtime_dependency "activesupport", [">= 6.1", "< 9"]
  spec.add_runtime_dependency "parallel", [">= 1.6", "< 3"]
  spec.add_runtime_dependency "faraday", "~> 2.0"
  spec.add_runtime_dependency "faraday-net_http_persistent", "~> 2.0"
  spec.add_runtime_dependency "moneta", "< 2"
  spec.add_runtime_dependency "connection_pool", ">= 2.2", "< 4"
  spec.add_runtime_dependency "rack", ">= 2.0.6", "< 4"
  spec.add_runtime_dependency "csv", "~> 3.3"
  spec.add_runtime_dependency "ostruct", "~> 0.6"

  # Optional dependencies for MFA (Multi-Factor Authentication) support
  # Users must add these to their Gemfile to use MFA features:
  #   gem 'rotp'    # For TOTP generation/verification
  #   gem 'rqrcode' # For QR code generation

  # Optional dependency for enhanced phone number validation
  # Users can add this to their Gemfile for comprehensive phone validation:
  #   gem 'phonelib' # For full ITU-T E.164 validation with libphonenumber data

  # Optional dependency for direct MongoDB queries and Atlas Search
  # Required for: Parse::MongoDB, Parse::AtlasSearch, mongo_direct query methods
  # Users can add this to their Gemfile for direct MongoDB access:
  #   gem 'mongo', '~> 2.18'
  # Note: The gem is loaded at runtime only when MongoDB features are used

  # Optional dependency for GraphQL schema type generation
  # Required for: Parse::GraphQL::TypeGenerator
  # Users can add this to their Gemfile for graphql-ruby type generation:
  #   gem 'graphql', '~> 2.0'
  # Note: The gem is loaded at runtime only when `require "parse/graphql"` is called.
  spec.add_development_dependency "graphql", "~> 2.0"

  #   spec.post_install_message = <<UPGRADE
  #
  # ** BREAKING CHANGES **
  #  The default `has_many` association form has changed from :array to :query.
  #  To use arrays, you must now pass `through: :array` option to `has_many`.
  #
  #  Visit: https://github.com/neurosynq/parse-stack-next/wiki/Changes-to-has_many-in-1.5.0
  #
  # UPGRADE
end

## Development
# After checking out the repo, run `bin/setup` to install dependencies. You can
# also run `bin/console` for an interactive prompt that will allow you to experiment.
#
# To install this gem onto your local machine, run `bundle exec rake install`.
# To release a new version, update the version number in `version.rb`, and then run
# `bundle exec rake release`, which will create a git tag for the version,
# push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).
