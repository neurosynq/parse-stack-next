# encoding: UTF-8
# frozen_string_literal: true

require_relative "../stack.rb"
require "active_support"
require "active_support/inflector"
require "active_support/core_ext"
require "rake"
require "rake/dsl_definition"

module Parse
  module Stack
    # Loads and installs all Parse::Stack related tasks in a rake file.
    def self.load_tasks
      Parse::Stack::Tasks.new.install_tasks
    end

    # Defines all the related Rails tasks for Parse.
    class Tasks
      include Rake::DSL if defined? Rake::DSL

      # Installs the rake tasks.
      def install_tasks
        if defined?(::Rails)
          unless Rake::Task.task_defined?("db:seed") || Rails.root.blank?
            namespace :db do
              desc "Seeds your database with by loading db/seeds.rb"
              task :seed => "parse:env" do
                load Rails.root.join("db", "seeds.rb")
              end
            end
          end
        end

        namespace :parse do
          task :env do
            if Rake::Task.task_defined?("environment")
              Rake::Task["environment"].invoke
              if defined?(::Rails)
                Rails.application.eager_load! if Rails.application.present?
              end
            end
          end

          task :verify_env => :env do
            unless Parse::Client.client?
              raise "Please make sure you have setup the Parse.setup configuration before invoking task. Usually done in the :environment task."
            end

            endpoint = ENV["HOOKS_URL"] || ""
            unless endpoint.starts_with?("http://") || endpoint.starts_with?("https://")
              raise "The ENV variable HOOKS_URL must be a <http/s> url : '#{endpoint}'. Ex. https://12345678.ngrok.io/webhooks"
            end
          end

          desc "Run auto_upgrade on all of your Parse models."
          task :upgrade => :env do
            puts "Auto Upgrading Parse schemas..."
            Parse.auto_upgrade! do |k|
              puts "[+] #{k}"
            end
          end

          namespace :references do
            # Enumerate every class that opted in to `parse_reference`. After
            # `:env` runs (which eager-loads Rails apps), `Parse::Object`'s
            # descendant set contains the full model graph; we filter to the
            # subset that exposes the `_parse_reference_fields` class reader.
            # @api private
            find_parse_reference_classes = lambda do
              klasses = Parse::Object.descendants.select do |k|
                k.respond_to?(:_parse_reference_fields) &&
                  Array(k._parse_reference_fields).any? &&
                  k.respond_to?(:parse_class) &&
                  k.parse_class.present?
              end
              filter = ENV["CLASS"]
              if filter.present?
                klasses = klasses.select { |k| k.parse_class == filter || k.name == filter }
                if klasses.empty?
                  warn "[parse:references] CLASS=#{filter} matched no class declaring parse_reference"
                end
              end
              klasses.uniq.sort_by { |k| k.parse_class }
            end

            desc "List every class that declares `parse_reference`."
            task :list => :env do
              klasses = find_parse_reference_classes.call
              if klasses.empty?
                puts "[parse:references] no classes declare parse_reference (CLASS filter: #{ENV["CLASS"].inspect})"
                next
              end
              klasses.each do |k|
                fields = Array(k._parse_reference_fields).map do |fn|
                  remote = (k.field_map[fn] || fn).to_s
                  fn == remote.to_sym ? fn.to_s : "#{fn} -> #{remote}"
                end
                puts "[#{k.parse_class}] #{fields.join(", ")}"
              end
            end

            desc "Backfill missing parse_reference values. ENV: CLASS, BATCH_SIZE (default 100), DRY_RUN=true"
            task :populate => :verify_env do
              klasses = find_parse_reference_classes.call
              if klasses.empty?
                puts "[parse:references:populate] nothing to do"
                next
              end

              batch_size = (ENV["BATCH_SIZE"] || "100").to_i
              batch_size = 100 if batch_size <= 0
              dry_run    = ENV["DRY_RUN"].to_s.downcase == "true"

              if dry_run
                puts "[parse:references:populate] DRY_RUN=true — no writes will be issued"
              end

              klasses.each do |klass|
                fields = Array(klass._parse_reference_fields)
                fields.each do |field_name|
                  populated_total = 0
                  scanned_total   = 0
                  loops_without_progress = 0
                  loop do
                    # Query for records where the reference column is null/
                    # missing. Parse Server treats `{ field: null }` as a match
                    # for both "explicitly null" and "field absent". The result
                    # set shrinks as we populate, so a fixed limit without
                    # offset naturally walks the unpopulated tail.
                    objects = klass.query(field_name => nil).limit(batch_size).results
                    break if objects.empty?
                    scanned_total += objects.size

                    if dry_run
                      eligible = objects.count { |o| o.id.present? }
                      puts "[#{klass.parse_class}.#{field_name}] [dry-run] #{eligible}/#{objects.size} eligible (cumulative scanned: #{scanned_total})"
                      # Without a write, the query returns the same objects
                      # forever. Stop after one batch in dry-run mode.
                      break
                    end

                    updated = klass.populate_parse_references!(objects)
                    populated_total += updated.size
                    puts "[#{klass.parse_class}.#{field_name}] populated #{updated.size}/#{objects.size} (cumulative: #{populated_total})"

                    # Defensive: if a full batch came back but none were
                    # populated (e.g. every record lacks an objectId, or all
                    # writes failed), we'd loop forever. Stop after two
                    # consecutive no-progress batches.
                    if updated.empty?
                      loops_without_progress += 1
                      if loops_without_progress >= 2
                        warn "[#{klass.parse_class}.#{field_name}] aborting — 2 consecutive batches made no progress (objects may lack objectIds or saves are failing)"
                        break
                      end
                    else
                      loops_without_progress = 0
                    end

                    break if objects.size < batch_size
                  end
                  puts "[#{klass.parse_class}.#{field_name}] done — #{populated_total} populated, #{scanned_total} scanned"
                end
              end
            end
          end # references

          namespace :mongo do
            namespace :indexes do
              # Enumerate classes that declared at least one `mongo_index`.
              # CLASS env var narrows to a single class by parse_class or
              # Ruby class name. Mirrors the references-task pattern.
              # @api private
              find_indexed_classes = lambda do
                klasses = Parse::Object.descendants.select do |k|
                  k.respond_to?(:mongo_index_declarations) &&
                    Array(k.mongo_index_declarations).any? &&
                    k.respond_to?(:parse_class) &&
                    k.parse_class.present?
                end
                filter = ENV["CLASS"]
                if filter.present?
                  klasses = klasses.select { |k| k.parse_class == filter || k.name == filter }
                  if klasses.empty?
                    warn "[parse:mongo:indexes] CLASS=#{filter} matched no class declaring mongo_index"
                  end
                end
                klasses.uniq.sort_by(&:parse_class)
              end

              # Print a per-collection plan section for one collection's
              # plan Hash (a single value from the multi-collection plan).
              print_one = lambda do |label, p|
                puts "  #{label}"
                puts "    capacity:    #{p[:capacity_used]} existing / #{Parse::Core::Indexing::MAX_INDEXES_PER_COLLECTION} max " \
                     "(#{p[:capacity_remaining]} remaining additive, #{p[:capacity_remaining_with_drop]} remaining if DROP=true)"
                if !p[:capacity_ok] && p[:capacity_ok_with_drop]
                  puts "    STATUS:      BLOCKED additive — would exceed 64-index cap; DROP=true would clear orphans and fit"
                elsif !p[:capacity_ok]
                  puts "    STATUS:      BLOCKED — would exceed 64-index cap even with DROP=true"
                end
                unless p[:parse_managed].empty?
                  puts "    managed:     #{p[:parse_managed].inspect}  (excluded from migration)"
                end
                if p[:to_create].any?
                  puts "    to_create:"
                  p[:to_create].each do |d|
                    flags = d[:options].dup
                    name  = flags.delete(:name) || "(auto)"
                    puts "      + #{d[:keys].inspect}  name=#{name}  opts=#{flags.inspect}"
                  end
                end
                if p[:in_sync].any?
                  puts "    in_sync:"
                  p[:in_sync].each { |d| puts "      = #{d[:keys].inspect}" }
                end
                if p[:conflicts].any?
                  puts "    conflicts:   (operator action required — neither create nor drop is safe)"
                  p[:conflicts].each do |c|
                    puts "      ! declared=#{c[:declared][:keys].inspect}"
                    puts "        existing=#{c[:existing].inspect}"
                  end
                end
                if p[:orphans].any?
                  puts "    orphans:     #{p[:orphans].inspect}"
                  puts "                 ^^ WARNING: any index not declared via `mongo_index` and not in"
                  puts "                    PARSE_MANAGED_INDEX_PATTERNS is listed here. This includes"
                  puts "                    DBA-created diagnostic indexes, indexes from other Parse SDKs,"
                  puts "                    and MongoDB Atlas index recommendations. Under DROP=true these"
                  puts "                    indexes WILL BE DROPPED. To preserve an index, declare it with"
                  puts "                    `mongo_index :field, name: \"<index_name>\"` on the model."
                end
              end

              # Print every plan in a class's migrator output (one entry
              # per target collection — parent + any `_Join:*` relation).
              print_plan = lambda do |klass|
                plans = Parse::Schema::IndexMigrator.new(klass).plan
                puts ""
                puts "=" * 70
                puts "#{klass.parse_class}  (#{klass.name})"
                plans.each do |coll, p|
                  print_one.call(coll, p)
                end
                plans
              end

              desc "Dry-run plan: declared mongo_index entries vs current MongoDB state. ENV: CLASS"
              task :plan => :env do
                klasses = find_indexed_classes.call
                if klasses.empty?
                  puts "[parse:mongo:indexes:plan] no classes declare mongo_index (CLASS filter: #{ENV["CLASS"].inspect})"
                  next
                end
                unless Parse::MongoDB.respond_to?(:enabled?) && Parse::MongoDB.enabled?
                  warn "[parse:mongo:indexes:plan] Parse::MongoDB is not enabled. Existing-index reads will return empty; declared lists will still print."
                end
                klasses.each { |k| print_plan.call(k) }
                puts ""
              end

              desc "Apply declared mongo_index changes. ENV: CLASS, DROP=true (drop orphans), ALLOW_SYSTEM_CLASSES=true"
              task :apply => :env do
                klasses = find_indexed_classes.call
                if klasses.empty?
                  puts "[parse:mongo:indexes:apply] nothing to do"
                  next
                end

                # Re-state the triple gate up-front. The primitives will
                # raise the same errors per call, but surfacing the
                # message here gives operators a single readable failure
                # instead of N stack traces.
                unless Parse::MongoDB.respond_to?(:writer_configured?) && Parse::MongoDB.writer_configured?
                  raise "[parse:mongo:indexes:apply] writer is not configured. " \
                        "Set up Parse::MongoDB.configure_writer(uri: ENV['MONGO_WRITER_URI']) in a rake initializer."
                end
                unless Parse::MongoDB.index_mutations_enabled
                  raise "[parse:mongo:indexes:apply] Parse::MongoDB.index_mutations_enabled is false. " \
                        "Set it to true explicitly in the rake initializer for this task."
                end
                unless ENV[Parse::MongoDB::MUTATION_ENV_KEY] == "1"
                  raise "[parse:mongo:indexes:apply] ENV[#{Parse::MongoDB::MUTATION_ENV_KEY.inspect}] must be \"1\"."
                end

                drop = ENV["DROP"].to_s.downcase == "true"
                puts "[parse:mongo:indexes:apply] mode: #{drop ? "additive + drop-orphans" : "additive only"}"
                if drop
                  puts ""
                  puts "  !!! DROP=true is set. Every index listed under 'orphans:' below WILL BE DROPPED."
                  puts "      Orphans include any index that does NOT match PARSE_MANAGED_INDEX_PATTERNS"
                  puts "      and is NOT declared via `mongo_index` on the model. This may capture"
                  puts "      DBA-created diagnostic indexes, indexes created by other SDKs, and MongoDB"
                  puts "      Atlas index recommendations. Review the plan output below carefully before"
                  puts "      proceeding. Cancel with Ctrl-C if anything in 'orphans:' is unexpected."
                  puts ""
                end

                klasses.each do |klass|
                  print_plan.call(klass)
                  results = Parse::Schema::IndexMigrator.new(klass).apply!(drop: drop)
                  puts ""
                  puts "[#{klass.parse_class}] applied:"
                  results.each do |coll, result|
                    puts "  #{coll}:"
                    if result[:capacity_blocked]
                      warn "    SKIPPED — capacity would be exceeded"
                      next
                    end
                    puts "    created:        #{result[:created].size}"
                    result[:created].each { |d| puts "      + #{d[:keys].inspect}" }
                    unless result[:skipped_exists].empty?
                      puts "    skipped_exists: #{result[:skipped_exists].size}"
                      result[:skipped_exists].each { |d| puts "      = #{d[:keys].inspect}" }
                    end
                    if drop && !result[:dropped].empty?
                      puts "    dropped:        #{result[:dropped].inspect}"
                    end
                    unless result[:conflicts].empty?
                      warn "    conflicts unresolved: #{result[:conflicts].size}"
                    end
                  end
                end
                puts ""
              end
            end # indexes

            namespace :search_indexes do
              # Enumerate classes that declared at least one
              # `mongo_search_index`. CLASS env var narrows by parse_class
              # or Ruby class name. Parallels find_indexed_classes in the
              # regular-index task.
              # @api private
              find_search_indexed_classes = lambda do
                klasses = Parse::Object.descendants.select do |k|
                  k.respond_to?(:mongo_search_index_declarations) &&
                    Array(k.mongo_search_index_declarations).any? &&
                    k.respond_to?(:parse_class) &&
                    k.parse_class.present?
                end
                filter = ENV["CLASS"]
                if filter.present?
                  klasses = klasses.select { |k| k.parse_class == filter || k.name == filter }
                  if klasses.empty?
                    warn "[parse:mongo:search_indexes] CLASS=#{filter} matched no class declaring mongo_search_index"
                  end
                end
                klasses.uniq.sort_by(&:parse_class)
              end

              # Print one model's search-index plan.
              print_search_plan = lambda do |klass|
                p = Parse::Schema::SearchIndexMigrator.new(klass).plan
                puts ""
                puts "=" * 70
                puts "#{klass.parse_class}  (#{klass.name})"
                puts "  collection:   #{p[:collection]}"
                unless p[:atlas_available]
                  puts "  STATUS:       atlas unavailable — `$listSearchIndexes` returned no data"
                  puts "                every declared index will be reported as to_create"
                end
                puts "  declared:     #{p[:declared].size}"
                if p[:to_create].any?
                  puts "  to_create:"
                  p[:to_create].each { |d| puts "    + #{d[:name].inspect}  type=#{d[:type]}" }
                end
                if p[:in_sync].any?
                  puts "  in_sync:"
                  p[:in_sync].each { |d| puts "    = #{d[:name].inspect}" }
                end
                if p[:drifted].any?
                  puts "  drifted:      (definition differs from atlas latestDefinition)"
                  p[:drifted].each do |entry|
                    puts "    ~ #{entry[:declared][:name].inspect}  existing.status=#{entry[:existing][:status]}"
                  end
                  puts "                 ^^ NOT updated by default. Pass UPDATE=true to rebuild."
                end
                if p[:orphans].any?
                  puts "  orphans:      #{p[:orphans].inspect}"
                  puts "                 ^^ search indexes present on the collection but not declared."
                  puts "                    Pass DROP=true to drop them. (Atlas Search has a separate"
                  puts "                    per-cluster quota — orphans don't count against the regular"
                  puts "                    64-index Mongo cap, but they do consume that quota.)"
                end
                p
              end

              desc "Dry-run plan: declared mongo_search_index entries vs current Atlas state. ENV: CLASS"
              task :plan => :env do
                klasses = find_search_indexed_classes.call
                if klasses.empty?
                  puts "[parse:mongo:search_indexes:plan] no classes declare mongo_search_index (CLASS filter: #{ENV["CLASS"].inspect})"
                  next
                end
                unless Parse::MongoDB.respond_to?(:enabled?) && Parse::MongoDB.enabled?
                  warn "[parse:mongo:search_indexes:plan] Parse::MongoDB is not enabled — existing-index reads will be empty."
                end
                klasses.each { |k| print_search_plan.call(k) }
                puts ""
              end

              desc "Apply declared mongo_search_index changes. ENV: CLASS, UPDATE=true (rebuild drifted), DROP=true (drop orphans), WAIT=true (block until READY), WAIT_TIMEOUT=600"
              task :apply => :env do
                klasses = find_search_indexed_classes.call
                if klasses.empty?
                  puts "[parse:mongo:search_indexes:apply] nothing to do"
                  next
                end

                # Triple gate — re-state up-front for one readable
                # failure instead of N stack traces from the primitives.
                unless Parse::MongoDB.respond_to?(:writer_configured?) && Parse::MongoDB.writer_configured?
                  raise "[parse:mongo:search_indexes:apply] writer is not configured. " \
                        "Set up Parse::MongoDB.configure_writer(uri: ENV['MONGO_WRITER_URI']) in a rake initializer."
                end
                unless Parse::MongoDB.index_mutations_enabled
                  raise "[parse:mongo:search_indexes:apply] Parse::MongoDB.index_mutations_enabled is false. " \
                        "Set it to true explicitly in the rake initializer for this task."
                end
                unless ENV[Parse::MongoDB::MUTATION_ENV_KEY] == "1"
                  raise "[parse:mongo:search_indexes:apply] ENV[#{Parse::MongoDB::MUTATION_ENV_KEY.inspect}] must be \"1\"."
                end

                update = ENV["UPDATE"].to_s.downcase == "true"
                drop   = ENV["DROP"].to_s.downcase   == "true"
                wait   = ENV["WAIT"].to_s.downcase   == "true"
                timeout = (ENV["WAIT_TIMEOUT"] || "600").to_i
                modes = []
                modes << "additive"
                modes << "update-drifted" if update
                modes << "drop-orphans"   if drop
                modes << "wait-for-ready (#{timeout}s)" if wait
                puts "[parse:mongo:search_indexes:apply] mode: #{modes.join(" + ")}"
                if drop
                  puts ""
                  puts "  !!! DROP=true is set. Every search index listed under 'orphans:' below WILL BE DROPPED."
                  puts ""
                end
                if update
                  puts ""
                  puts "  !!! UPDATE=true is set. Every search index listed under 'drifted:' WILL BE REBUILT."
                  puts "      Atlas Search rebuilds run asynchronously; queries hit the old definition until READY."
                  puts ""
                end

                klasses.each do |klass|
                  print_search_plan.call(klass)
                  results = Parse::Schema::SearchIndexMigrator.new(klass).apply!(
                    update: update, drop: drop, wait: wait, timeout: timeout,
                  )
                  puts ""
                  puts "[#{klass.parse_class}] applied:"
                  puts "  created:         #{results[:created].size}"
                  results[:created].each { |d| puts "    + #{d[:name]}" }
                  unless results[:skipped_exists].empty?
                    puts "  skipped_exists:  #{results[:skipped_exists].size}"
                    results[:skipped_exists].each { |d| puts "    = #{d[:name]}  (raced — already present at apply time)" }
                  end
                  unless results[:in_sync].empty?
                    puts "  in_sync:         #{results[:in_sync].size}"
                  end
                  if update && !results[:updated].empty?
                    puts "  updated:         #{results[:updated].inspect}"
                  elsif !results[:drifted_skipped].empty?
                    puts "  drifted_skipped: #{results[:drifted_skipped].inspect}  (pass UPDATE=true to rebuild)"
                  end
                  if drop && !results[:dropped].empty?
                    puts "  dropped:         #{results[:dropped].inspect}"
                  elsif !results[:orphans_skipped].empty?
                    puts "  orphans_skipped: #{results[:orphans_skipped].inspect}  (pass DROP=true to remove)"
                  end
                  unless results[:wait_results].empty?
                    puts "  wait_results:"
                    results[:wait_results].each { |name, outcome| puts "    #{name}: #{outcome}" }
                  end
                end
                puts ""
              end
            end # search_indexes
          end # mongo

          namespace :webhooks do
            desc "Register local webhooks with Parse server"
            task :register => :verify_env do
              endpoint = ENV["HOOKS_URL"]
              puts "Registering Parse Webhooks @ #{endpoint}"
              Rake::Task["parse:webhooks:register:functions"].invoke
              Rake::Task["parse:webhooks:register:triggers"].invoke
            end

            desc "List all webhooks and triggers registered with the Parse Server"
            task :list => :verify_env do
              Rake::Task["parse:webhooks:list:functions"].invoke
              Rake::Task["parse:webhooks:list:triggers"].invoke
            end

            desc "Remove all locally registered webhooks from the Parse Application."
            task :remove => :verify_env do
              Rake::Task["parse:webhooks:remove:functions"].invoke
              Rake::Task["parse:webhooks:remove:triggers"].invoke
            end

            namespace :list do
              task :functions => :verify_env do
                endpoint = ENV["HOOKS_URL"] || "-"
                Parse.client.functions.each do |r|
                  name = r["functionName"]
                  url = r["url"]
                  star = url.starts_with?(endpoint) ? "*" : " "
                  puts "[#{star}] #{name} -> #{url}"
                end
              end

              task :triggers => :verify_env do
                endpoint = ENV["HOOKS_URL"] || "-"
                triggers = Parse.client.triggers.results
                triggers.sort! { |x, y| [x["className"], x["triggerName"]] <=> [y["className"], y["triggerName"]] }
                triggers.each do |r|
                  name = r["className"]
                  trigger = r["triggerName"]
                  url = r["url"]
                  star = url.starts_with?(endpoint) ? "*" : " "
                  puts "[#{star}] #{name}.#{trigger} -> #{url}"
                end
              end
            end

            namespace :register do
              task :functions => :verify_env do
                endpoint = ENV["HOOKS_URL"]
                Parse::Webhooks.register_functions!(endpoint) do |name|
                  puts "[+] function - #{name}"
                end
              end

              task :triggers => :verify_env do
                endpoint = ENV["HOOKS_URL"]
                Parse::Webhooks.register_triggers!(endpoint, **{ include_wildcard: true }) do |trigger, name|
                  puts "[+] #{trigger.to_s.ljust(12, " ")} - #{name}"
                end
              end
            end

            namespace :remove do
              task :functions => :verify_env do
                Parse::Webhooks.remove_all_functions! do |name|
                  puts "[-] function - #{name}"
                end
              end

              task :triggers => :verify_env do
                Parse::Webhooks.remove_all_triggers! do |trigger, name|
                  puts "[-] #{trigger.to_s.ljust(12, " ")} - #{name}"
                end
              end
            end
          end # webhooks
        end # webhooks namespace
      end
    end # Tasks
  end # Webhooks
end # Parse
