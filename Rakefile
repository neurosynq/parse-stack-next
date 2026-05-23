#!/usr/bin/env rake
require "bundler/gem_tasks"
require "yard"
require "rake/testtask"

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
      system("PARSE_TEST_USE_DOCKER=true ruby -Itest #{file}") || exit(1)
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

      system("PARSE_TEST_USE_DOCKER=true ruby -Itest #{file}") || exit(1)
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
end

task :default => :test

task :console do
  exec "./bin/console"
end
task :c => :console

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
  t.options = ["-o", "doc/parse-stack"] # optional
  t.stats_options = ["--list-undoc"]         # optional
end
