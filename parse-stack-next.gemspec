# coding: utf-8
lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "parse/stack/version"

Gem::Specification.new do |spec|
  spec.name = "parse-stack-next"
  spec.version = Parse::Stack::VERSION
  spec.authors = ["Adrian Curtin", "Anthony Persaud", "Henry Spindell"]
  spec.email = ["adrian+parse-stack@neurosynq.net"]

  spec.summary = %q{Parse Server SDK for Ruby — ORM, queries, auth, and MongoDB-direct access}
  spec.description = %q{Production-grade Ruby client for Parse Server. Map Parse classes to Ruby models with typed properties, associations, and validations; build queries with a chainable DataMapper-style DSL; handle auth, sessions, MFA, cloud code webhooks, and push; introspect and migrate schemas; manage role hierarchies; scope access with per-agent ACL/CLP; generate GraphQL types; run Atlas Search and vector search; and bypass REST for high-throughput reads via the MongoDB-direct pipeline.}
  spec.homepage = "https://github.com/neurosynq/parse-stack-next"
  spec.license = "MIT"

  spec.metadata = {
    "homepage_uri" => "https://github.com/neurosynq/parse-stack-next",
    "source_code_uri" => "https://github.com/neurosynq/parse-stack-next",
    "changelog_uri" => "https://github.com/neurosynq/parse-stack-next/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/neurosynq/parse-stack-next/issues",
    "documentation_uri" => "https://neurosynq.github.io/parse-stack-next/",
    "rubygems_mfa_required" => "true",
  }

  # Ship only what an SDK consumer needs: the library, executables, the
  # rendered guides + copy-paste examples, the README banner asset, and the
  # standard metadata files. Everything else that is tracked purely for
  # development — .github/, .vscode/, .bundle/, .env.*, scripts/, config/,
  # Makefile, Rakefile, Gemfile(.lock), and dotfiles — is intentionally
  # excluded so ~1MB of packaging noise isn't shipped to every install.
  spec.files = `git ls-files -z`.split("\x0").select do |f|
    f.start_with?("lib/", "bin/", "docs/", "examples/", "assets/") ||
      %w[
        README.md
        CHANGELOG.md
        LICENSE.txt
        SECURITY.md
        parse-stack-next.gemspec
      ].include?(f)
  end.reject do |f|
    # Internal dev docs that live under docs/ but aren't consumer-facing.
    f == "docs/client_sdk_todo.md"
  end
  spec.bindir = "bin"
  spec.executables = ["parse-console"] #spec.files.grep(%r{^bin/pstack/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 3.2"

  spec.add_runtime_dependency "activemodel", [">= 6.1", "< 9"]
  spec.add_runtime_dependency "activesupport", [">= 6.1", "< 9"]
  spec.add_runtime_dependency "parallel", [">= 1.6", "< 3"]
  spec.add_runtime_dependency "faraday", [">= 2.14.3", "< 3"]
  spec.add_runtime_dependency "faraday-net_http_persistent", "~> 2.0"
  spec.add_runtime_dependency "moneta", "< 2"
  spec.add_runtime_dependency "connection_pool", ">= 2.2", "< 4"
  # Rack's 2026-04 advisories are fixed per branch: 2.2.23, 3.1.21, and
  # 3.2.6 (the 3.0 line has no fixed release). A single floor cannot express
  # that, so the released vulnerable 3.x versions are excluded by name and
  # Rack 2.2 applications stay supported.
  rack_vulnerable_3x =
    %w[3.0.0 3.0.1 3.0.2 3.0.3 3.0.4 3.0.4.1 3.0.4.2 3.0.5 3.0.6 3.0.6.1 3.0.7
       3.0.8 3.0.9 3.0.9.1 3.0.10 3.0.11 3.0.12 3.0.13 3.0.14 3.0.15 3.0.16
       3.0.17 3.0.18] +
    (0..20).map { |patch| "3.1.#{patch}" } +
    (0..5).map { |patch| "3.2.#{patch}" }
  spec.add_runtime_dependency "rack", [">= 2.2.23", "< 4"] + rack_vulnerable_3x.map { |v| "!= #{v}" }
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
  #   gem 'mongo', '>= 2.26', '< 3'
  # mongo 2.26.0 or newer is recommended: it fixes CVE-2026-88030 and is
  # required against MongoDB 9.0 servers.
  # Note: The gem is loaded at runtime only when MongoDB features are used

  # Optional dependency for GraphQL schema type generation
  # Required for: Parse::GraphQL::TypeGenerator
  # Users can add this to their Gemfile for graphql-ruby type generation:
  #   gem 'graphql', '>= 2.6.9', '< 3'
  # graphql 2.6.9 or newer is recommended (GHSA-j7xr-4g94-r9h3, GHSA-rmxg-5p3r-j6hh).
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
