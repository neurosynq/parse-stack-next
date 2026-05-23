require_relative "../../test_helper_integration"
require "timeout"

# Tests for Parse Stack 2.1.10 array constraint features
class ArrayConstraints210IntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  # Timeout helper method
  def with_timeout(seconds, description)
    Timeout.timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{description} timed out after #{seconds} seconds"
  end

  # Test model with array field for simple values
  class TaggedItem210 < Parse::Object
    parse_class "TaggedItem210"
    property :name, :string
    property :tags, :array
  end

  # Test model with array of hashes (for elem_match)
  class OrderItem < Parse::Object
    parse_class "OrderItem210"
    property :name, :string
    property :items, :array  # Array of hashes like { product: "SKU", quantity: 5, price: 10.0 }
  end

  # ==========================================================================
  # Test 1: :any constraint (alias for $in)
  # ==========================================================================
  def test_any_constraint
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      puts "\n=== Testing :any Constraint (alias for $in) ==="

      with_timeout(10, "creating test data") do
        TaggedItem210.new(name: "rock_only", tags: ["rock"]).save
        TaggedItem210.new(name: "pop_only", tags: ["pop"]).save
        TaggedItem210.new(name: "rock_and_pop", tags: ["rock", "pop"]).save
        TaggedItem210.new(name: "jazz_only", tags: ["jazz"]).save
        TaggedItem210.new(name: "classical", tags: ["classical", "baroque"]).save
      end

      with_timeout(5, "testing :any constraint") do
        begin
          # Test :tags.any => ["rock", "pop"] - should match items containing ANY of these
          results = TaggedItem210.query(:tags.any => ["rock", "pop"]).all
          names = results.map(&:name).sort

          puts "Query: :tags.any => ['rock', 'pop']"
          puts "Results: #{names.inspect}"

          # Should match: rock_only, pop_only, rock_and_pop
          # Should NOT match: jazz_only, classical
          assert_includes names, "rock_only", "any should match items with rock"
          assert_includes names, "pop_only", "any should match items with pop"
          assert_includes names, "rock_and_pop", "any should match items with rock or pop"
          refute_includes names, "jazz_only", "any should NOT match items without rock or pop"
          refute_includes names, "classical", "any should NOT match items without rock or pop"

          assert_equal 3, results.length, "Should find exactly 3 items"

          puts "✅ :any constraint works correctly!"
        rescue => e
          puts "❌ :any constraint failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(5).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 2: :none constraint (alias for $nin)
  # ==========================================================================
  def test_none_constraint
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      puts "\n=== Testing :none Constraint (alias for $nin) ==="

      with_timeout(10, "creating test data") do
        TaggedItem210.new(name: "rock_only", tags: ["rock"]).save
        TaggedItem210.new(name: "pop_only", tags: ["pop"]).save
        TaggedItem210.new(name: "rock_and_pop", tags: ["rock", "pop"]).save
        TaggedItem210.new(name: "jazz_only", tags: ["jazz"]).save
        TaggedItem210.new(name: "classical", tags: ["classical", "baroque"]).save
      end

      with_timeout(5, "testing :none constraint") do
        begin
          # Test :tags.none => ["rock", "pop"] - should match items containing NONE of these
          results = TaggedItem210.query(:tags.none => ["rock", "pop"]).all
          names = results.map(&:name).sort

          puts "Query: :tags.none => ['rock', 'pop']"
          puts "Results: #{names.inspect}"

          # Should match: jazz_only, classical
          # Should NOT match: rock_only, pop_only, rock_and_pop
          refute_includes names, "rock_only", "none should NOT match items with rock"
          refute_includes names, "pop_only", "none should NOT match items with pop"
          refute_includes names, "rock_and_pop", "none should NOT match items with rock or pop"
          assert_includes names, "jazz_only", "none should match items without rock or pop"
          assert_includes names, "classical", "none should match items without rock or pop"

          assert_equal 2, results.length, "Should find exactly 2 items"

          puts "✅ :none constraint works correctly!"
        rescue => e
          puts "❌ :none constraint failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(5).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 3: :superset_of constraint (alias for $all)
  # ==========================================================================
  def test_superset_of_constraint
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      puts "\n=== Testing :superset_of Constraint (alias for $all) ==="

      with_timeout(10, "creating test data") do
        TaggedItem210.new(name: "rock_only", tags: ["rock"]).save
        TaggedItem210.new(name: "rock_and_pop", tags: ["rock", "pop"]).save
        TaggedItem210.new(name: "rock_pop_jazz", tags: ["rock", "pop", "jazz"]).save
        TaggedItem210.new(name: "pop_only", tags: ["pop"]).save
      end

      with_timeout(5, "testing :superset_of constraint") do
        begin
          # Test :tags.superset_of => ["rock", "pop"] - should match items containing ALL of these
          results = TaggedItem210.query(:tags.superset_of => ["rock", "pop"]).all
          names = results.map(&:name).sort

          puts "Query: :tags.superset_of => ['rock', 'pop']"
          puts "Results: #{names.inspect}"

          # Should match: rock_and_pop, rock_pop_jazz (both have rock AND pop)
          # Should NOT match: rock_only (missing pop), pop_only (missing rock)
          assert_includes names, "rock_and_pop", "superset_of should match exact set"
          assert_includes names, "rock_pop_jazz", "superset_of should match superset"
          refute_includes names, "rock_only", "superset_of should NOT match if missing elements"
          refute_includes names, "pop_only", "superset_of should NOT match if missing elements"

          assert_equal 2, results.length, "Should find exactly 2 items"

          puts "✅ :superset_of constraint works correctly!"
        rescue => e
          puts "❌ :superset_of constraint failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(5).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 4: :elem_match constraint (native $elemMatch)
  # ==========================================================================
  def test_elem_match_constraint
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      puts "\n=== Testing :elem_match Constraint ==="

      with_timeout(10, "creating test data") do
        # Create orders with items arrays containing hashes
        OrderItem.new(
          name: "order1",
          items: [
            { "product" => "SKU001", "quantity" => 5, "price" => 10.0 },
            { "product" => "SKU002", "quantity" => 2, "price" => 25.0 },
          ],
        ).save

        OrderItem.new(
          name: "order2",
          items: [
            { "product" => "SKU001", "quantity" => 10, "price" => 10.0 },
            { "product" => "SKU003", "quantity" => 1, "price" => 100.0 },
          ],
        ).save

        OrderItem.new(
          name: "order3",
          items: [
            { "product" => "SKU002", "quantity" => 3, "price" => 25.0 },
            { "product" => "SKU004", "quantity" => 7, "price" => 15.0 },
          ],
        ).save
      end

      with_timeout(5, "testing :elem_match constraint") do
        begin
          # Test :items.elem_match - find orders with SKU001 and quantity > 7
          results = OrderItem.query(:items.elem_match => {
                                      "product" => "SKU001",
                                      "quantity" => { "$gt" => 7 },
                                    }).all
          names = results.map(&:name)

          puts "Query: :items.elem_match => { product: 'SKU001', quantity: { $gt: 7 } }"
          puts "Results: #{names.inspect}"

          # Should match: order2 (has SKU001 with quantity 10)
          # Should NOT match: order1 (SKU001 quantity is 5), order3 (no SKU001)
          assert_equal 1, results.length, "Should find exactly 1 order"
          assert_equal "order2", results.first.name, "Should find order2"

          puts "✅ :elem_match constraint works correctly!"
        rescue => e
          puts "❌ :elem_match constraint failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(5).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 5: :subset_of constraint (uses aggregation)
  # ==========================================================================
  def test_subset_of_constraint
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      puts "\n=== Testing :subset_of Constraint ==="

      with_timeout(10, "creating test data") do
        TaggedItem210.new(name: "rock_only", tags: ["rock"]).save
        TaggedItem210.new(name: "rock_and_pop", tags: ["rock", "pop"]).save
        TaggedItem210.new(name: "rock_and_metal", tags: ["rock", "metal"]).save  # metal not in allowed set
        TaggedItem210.new(name: "empty", tags: []).save
      end

      with_timeout(5, "testing :subset_of constraint") do
        begin
          # Test :tags.subset_of => ["rock", "pop", "jazz"] - tags must only contain elements from this set
          results = TaggedItem210.query(:tags.subset_of => ["rock", "pop", "jazz"]).all
          names = results.map(&:name).sort

          puts "Query: :tags.subset_of => ['rock', 'pop', 'jazz']"
          puts "Results: #{names.inspect}"

          # Should match: rock_only (["rock"] subset of allowed), rock_and_pop, empty ([] is subset of anything)
          # Should NOT match: rock_and_metal (contains "metal" which is not in allowed set)
          assert_includes names, "rock_only", "subset_of should match when all elements in allowed set"
          assert_includes names, "rock_and_pop", "subset_of should match when all elements in allowed set"
          assert_includes names, "empty", "subset_of should match empty array (empty set is subset of any set)"
          refute_includes names, "rock_and_metal", "subset_of should NOT match when element not in allowed set"

          assert_equal 3, results.length, "Should find exactly 3 items"

          puts "✅ :subset_of constraint works correctly!"
        rescue => e
          puts "❌ :subset_of constraint failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(5).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 6: :first constraint (uses aggregation)
  # ==========================================================================
  def test_first_constraint
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      puts "\n=== Testing :first Constraint ==="

      with_timeout(10, "creating test data") do
        TaggedItem210.new(name: "featured_first", tags: ["featured", "rock", "pop"]).save
        TaggedItem210.new(name: "rock_first", tags: ["rock", "featured", "pop"]).save
        TaggedItem210.new(name: "featured_only", tags: ["featured"]).save
        TaggedItem210.new(name: "no_featured", tags: ["rock", "pop"]).save
        TaggedItem210.new(name: "empty", tags: []).save
      end

      with_timeout(5, "testing :first constraint") do
        begin
          # Test :tags.first => "featured" - first element must be "featured"
          results = TaggedItem210.query(:tags.first => "featured").all
          names = results.map(&:name).sort

          puts "Query: :tags.first => 'featured'"
          puts "Results: #{names.inspect}"

          # Should match: featured_first, featured_only
          # Should NOT match: rock_first (featured is not first), no_featured, empty
          assert_includes names, "featured_first", "first should match when first element matches"
          assert_includes names, "featured_only", "first should match single-element array"
          refute_includes names, "rock_first", "first should NOT match when element is not first"
          refute_includes names, "no_featured", "first should NOT match when element not present"
          refute_includes names, "empty", "first should NOT match empty array"

          assert_equal 2, results.length, "Should find exactly 2 items"

          puts "✅ :first constraint works correctly!"
        rescue => e
          puts "❌ :first constraint failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(5).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 7: :last constraint (uses aggregation)
  # ==========================================================================
  def test_last_constraint
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      puts "\n=== Testing :last Constraint ==="

      with_timeout(10, "creating test data") do
        TaggedItem210.new(name: "archived_last", tags: ["rock", "pop", "archived"]).save
        TaggedItem210.new(name: "archived_middle", tags: ["rock", "archived", "pop"]).save
        TaggedItem210.new(name: "archived_only", tags: ["archived"]).save
        TaggedItem210.new(name: "no_archived", tags: ["rock", "pop"]).save
        TaggedItem210.new(name: "empty", tags: []).save
      end

      with_timeout(5, "testing :last constraint") do
        begin
          # Test :tags.last => "archived" - last element must be "archived"
          results = TaggedItem210.query(:tags.last => "archived").all
          names = results.map(&:name).sort

          puts "Query: :tags.last => 'archived'"
          puts "Results: #{names.inspect}"

          # Should match: archived_last, archived_only
          # Should NOT match: archived_middle (archived is not last), no_archived, empty
          assert_includes names, "archived_last", "last should match when last element matches"
          assert_includes names, "archived_only", "last should match single-element array"
          refute_includes names, "archived_middle", "last should NOT match when element is not last"
          refute_includes names, "no_archived", "last should NOT match when element not present"
          refute_includes names, "empty", "last should NOT match empty array"

          assert_equal 2, results.length, "Should find exactly 2 items"

          puts "✅ :last constraint works correctly!"
        rescue => e
          puts "❌ :last constraint failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(5).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 8: :empty_or_nil combined with date constraints
  # ==========================================================================
  def test_empty_or_nil_with_date_constraint
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      puts "\n=== Testing :empty_or_nil Combined with Date Constraint ==="

      now = Time.now
      one_day_ago = now - 86400
      two_days_ago = now - 172800

      with_timeout(10, "creating test data") do
        # Items with empty/nil tags at different times
        item1 = TaggedItem210.new(name: "empty_recent", tags: [])
        item1.save

        item2 = TaggedItem210.new(name: "nil_recent", tags: nil)
        item2.save

        item3 = TaggedItem210.new(name: "has_tags_recent", tags: ["rock", "pop"])
        item3.save

        item4 = TaggedItem210.new(name: "empty_old", tags: [])
        item4.save

        item5 = TaggedItem210.new(name: "has_tags_old", tags: ["jazz"])
        item5.save
      end

      with_timeout(10, "testing :empty_or_nil with date constraint") do
        begin
          # Test combining empty_or_nil with created_at constraint
          # Should find items where tags is empty/nil AND created recently
          cutoff_time = one_day_ago

          puts "Query: :tags.empty_or_nil => true, :created_at.gte => #{cutoff_time}"

          # First, verify empty_or_nil works alone
          empty_nil_results = TaggedItem210.query(:tags.empty_or_nil => true).all
          empty_nil_names = empty_nil_results.map(&:name).sort
          puts "empty_or_nil alone results: #{empty_nil_names.inspect}"

          # Count should match .all.count
          empty_nil_count = TaggedItem210.query(:tags.empty_or_nil => true).count
          puts "empty_or_nil count: #{empty_nil_count}, all.count: #{empty_nil_results.count}"
          assert_equal empty_nil_results.count, empty_nil_count, "count should match all.count for empty_or_nil"

          # Now test with date constraint
          combined_results = TaggedItem210.query(
            :tags.empty_or_nil => true,
            :created_at.gte => cutoff_time,
          ).all
          combined_names = combined_results.map(&:name).sort
          puts "Combined (empty_or_nil + created_at.gte) results: #{combined_names.inspect}"

          # Count should match .all.count for combined query
          combined_count = TaggedItem210.query(
            :tags.empty_or_nil => true,
            :created_at.gte => cutoff_time,
          ).count
          puts "Combined count: #{combined_count}, all.count: #{combined_results.count}"
          assert_equal combined_results.count, combined_count, "count should match all.count for combined query"

          # All results should have empty or nil tags
          combined_results.each do |item|
            tags = item.tags
            assert(tags.nil? || tags.empty?, "Item #{item.name} should have empty or nil tags, got: #{tags.inspect}")
          end

          # All results should be created after cutoff
          combined_results.each do |item|
            assert item.created_at >= cutoff_time, "Item #{item.name} should be created after cutoff"
          end

          puts "✅ :empty_or_nil combined with date constraint works correctly!"
        rescue => e
          puts "❌ :empty_or_nil with date constraint failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(5).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 9: :empty_or_nil with multiple constraints (category + date)
  # ==========================================================================
  def test_empty_or_nil_with_multiple_constraints
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      puts "\n=== Testing :empty_or_nil with Multiple Constraints ==="

      with_timeout(10, "creating test data") do
        # Mix of items with different name prefixes and tag states
        TaggedItem210.new(name: "report_empty", tags: []).save
        TaggedItem210.new(name: "report_nil", tags: nil).save
        TaggedItem210.new(name: "report_has_tags", tags: ["important"]).save
        TaggedItem210.new(name: "article_empty", tags: []).save
        TaggedItem210.new(name: "article_has_tags", tags: ["featured"]).save
      end

      with_timeout(10, "testing :empty_or_nil with multiple constraints") do
        begin
          # Query: name starts with "report" AND tags is empty/nil
          puts "Query: name starts with 'report', :tags.empty_or_nil => true"

          results = TaggedItem210.query(
            :name.starts_with => "report",
            :tags.empty_or_nil => true,
          ).all
          names = results.map(&:name).sort
          puts "Results: #{names.inspect}"

          # Should match: report_empty, report_nil
          # Should NOT match: report_has_tags (has tags), article_* (wrong prefix)
          assert_includes names, "report_empty", "Should match report with empty tags"
          assert_includes names, "report_nil", "Should match report with nil tags"
          refute_includes names, "report_has_tags", "Should NOT match report with tags"
          refute_includes names, "article_empty", "Should NOT match article (wrong prefix)"

          assert_equal 2, results.length, "Should find exactly 2 items"

          # Verify count matches
          count = TaggedItem210.query(
            :name.starts_with => "report",
            :tags.empty_or_nil => true,
          ).count
          assert_equal results.count, count, "count should match all.count"
          puts "Count: #{count}, all.count: #{results.count}"

          puts "✅ :empty_or_nil with multiple constraints works correctly!"
        rescue => e
          puts "❌ :empty_or_nil with multiple constraints failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(5).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 10: :empty_or_nil with pointer constraints and date constraints
  # This tests the specific pattern used in Report.calculate_report_version
  # ==========================================================================

  # Additional models for pointer tests
  class ProjectTest210 < Parse::Object
    parse_class "ProjectTest210"
    property :name, :string
    property :status, :string  # Added for lookup tests
  end

  class TeamTest210 < Parse::Object
    parse_class "TeamTest210"
    property :name, :string
  end

  class ReportTest210 < Parse::Object
    parse_class "ReportTest210"
    property :name, :string
    property :topics, :array
    property :status, :string
    belongs_to :project, as: :project_test210
    belongs_to :team, as: :team_test210
  end

  def test_empty_or_nil_with_pointer_and_date_constraints
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      puts "\n=== Testing :empty_or_nil with Pointer + Date Constraints ==="

      project = nil
      team = nil
      reference_time = nil

      with_timeout(15, "creating test data with pointers") do
        # Create parent objects
        project = ProjectTest210.new(name: "Test Project")
        project.save
        puts "Created project: #{project.id}"

        team = TeamTest210.new(name: "Test Team")
        team.save
        puts "Created team: #{team.id}"

        # Sleep briefly to ensure distinct timestamps
        sleep(0.5)

        # Create reports with different topic states
        # Report 1: empty topics array
        r1 = ReportTest210.new(name: "report_empty_topics", project: project, team: team, status: "pending", topics: [])
        r1.save
        puts "r1 (empty topics) id=#{r1.id}, created_at=#{r1.created_at}"

        sleep(0.3)

        # Report 2: nil topics (field not set explicitly)
        r2 = ReportTest210.new(name: "report_nil_topics", project: project, team: team, status: "pending")
        r2.save
        puts "r2 (nil topics) id=#{r2.id}, created_at=#{r2.created_at}"

        # Capture reference time AFTER some reports are created
        sleep(0.3)
        reference_time = Time.now.utc
        puts "Reference time: #{reference_time}"

        sleep(0.3)

        # Report 3: with topics (created after reference time)
        r3 = ReportTest210.new(name: "report_with_topics", project: project, team: team, status: "pending", topics: ["Safety", "Quality"])
        r3.save
        puts "r3 (with topics) id=#{r3.id}, created_at=#{r3.created_at}"

        # Report 4: empty topics but different project (should not match)
        other_project = ProjectTest210.new(name: "Other Project")
        other_project.save
        r4 = ReportTest210.new(name: "report_other_project", project: other_project, team: team, status: "pending", topics: [])
        r4.save
        puts "r4 (other project) id=#{r4.id}, created_at=#{r4.created_at}"

        # Report 5: empty topics created after reference time
        sleep(0.3)
        r5 = ReportTest210.new(name: "report_empty_after_ref", project: project, team: team, status: "complete", topics: [])
        r5.save
        puts "r5 (empty, after ref) id=#{r5.id}, created_at=#{r5.created_at}"
      end

      with_timeout(15, "testing :empty_or_nil with pointer + date constraints") do
        begin
          # Test 1: empty_or_nil with pointer constraint only (no date)
          puts "\n--- Test: empty_or_nil + pointer constraint only ---"
          results1 = ReportTest210.query(
            project: project,
            :topics.empty_or_nil => true,
          ).all
          names1 = results1.map(&:name).sort
          puts "Query: project=#{project.id}, :topics.empty_or_nil => true"
          puts "Results: #{names1.inspect}"

          assert_includes names1, "report_empty_topics", "Should match report with empty topics"
          assert_includes names1, "report_nil_topics", "Should match report with nil topics"
          assert_includes names1, "report_empty_after_ref", "Should match report with empty topics (after ref)"
          refute_includes names1, "report_with_topics", "Should NOT match report with topics"
          refute_includes names1, "report_other_project", "Should NOT match report from other project"

          count1 = ReportTest210.query(project: project, :topics.empty_or_nil => true).count
          puts "Count: #{count1}, all.count: #{results1.count}"
          assert_equal results1.count, count1, "count should match all.count"

          puts "✅ empty_or_nil + pointer constraint works!"

          # Test 2: empty_or_nil with pointer AND date constraint
          puts "\n--- Test: empty_or_nil + pointer + date constraint ---"
          results2 = ReportTest210.query(
            project: project,
            :topics.empty_or_nil => true,
            :created_at.lt => reference_time,
          ).all
          names2 = results2.map(&:name).sort
          puts "Query: project=#{project.id}, :topics.empty_or_nil => true, :created_at.lt => #{reference_time}"
          puts "Results: #{names2.inspect}"

          assert_includes names2, "report_empty_topics", "Should match report with empty topics before ref time"
          assert_includes names2, "report_nil_topics", "Should match report with nil topics before ref time"
          refute_includes names2, "report_empty_after_ref", "Should NOT match report created after ref time"
          refute_includes names2, "report_with_topics", "Should NOT match report with topics"

          count2 = ReportTest210.query(
            project: project,
            :topics.empty_or_nil => true,
            :created_at.lt => reference_time,
          ).count
          puts "Count: #{count2}, all.count: #{results2.count}"
          assert_equal results2.count, count2, "count should match all.count for pointer+date+empty_or_nil"

          puts "✅ empty_or_nil + pointer + date constraint works!"

          # Test 3: Multiple pointer constraints + empty_or_nil + date
          puts "\n--- Test: multiple pointers + empty_or_nil + date ---"
          results3 = ReportTest210.query(
            project: project,
            team: team,
            :topics.empty_or_nil => true,
            :created_at.lt => reference_time,
          ).all
          names3 = results3.map(&:name).sort
          puts "Query: project=#{project.id}, team=#{team.id}, :topics.empty_or_nil => true, :created_at.lt => #{reference_time}"
          puts "Results: #{names3.inspect}"

          assert_equal 2, results3.count, "Should match exactly 2 reports"

          count3 = ReportTest210.query(
            project: project,
            team: team,
            :topics.empty_or_nil => true,
            :created_at.lt => reference_time,
          ).count
          puts "Count: #{count3}"
          assert_equal results3.count, count3, "count should match all.count for multiple pointers"

          puts "✅ multiple pointers + empty_or_nil + date works!"
        rescue => e
          puts "❌ Test failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(10).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 11: :size with pointer constraints and date constraints
  # ==========================================================================
  def test_size_with_pointer_and_date_constraints
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      puts "\n=== Testing :size with Pointer + Date Constraints ==="

      project = nil
      reference_time = nil

      with_timeout(15, "creating test data with pointers") do
        # Create parent object
        project = ProjectTest210.new(name: "Size Test Project")
        project.save
        puts "Created project: #{project.id}"

        sleep(0.3)

        # Create reports with different topic counts
        r1 = ReportTest210.new(name: "report_2_topics", project: project, status: "pending", topics: ["A", "B"])
        r1.save
        puts "r1 (2 topics) id=#{r1.id}"

        r2 = ReportTest210.new(name: "report_3_topics", project: project, status: "pending", topics: ["A", "B", "C"])
        r2.save
        puts "r2 (3 topics) id=#{r2.id}"

        # Capture reference time
        sleep(0.3)
        reference_time = Time.now.utc
        puts "Reference time: #{reference_time}"
        sleep(0.3)

        r3 = ReportTest210.new(name: "report_2_topics_after", project: project, status: "pending", topics: ["X", "Y"])
        r3.save
        puts "r3 (2 topics, after ref) id=#{r3.id}"

        # Different project
        other_project = ProjectTest210.new(name: "Other Size Project")
        other_project.save
        r4 = ReportTest210.new(name: "report_2_topics_other", project: other_project, status: "pending", topics: ["M", "N"])
        r4.save
        puts "r4 (2 topics, other project) id=#{r4.id}"
      end

      with_timeout(15, "testing :size with pointer + date constraints") do
        begin
          # Test: size with pointer constraint
          puts "\n--- Test: size + pointer constraint ---"
          results1 = ReportTest210.query(
            project: project,
            :topics.size => 2,
          ).all
          names1 = results1.map(&:name).sort
          puts "Query: project=#{project.id}, :topics.size => 2"
          puts "Results: #{names1.inspect}"

          assert_includes names1, "report_2_topics", "Should match report with 2 topics"
          assert_includes names1, "report_2_topics_after", "Should match report with 2 topics (after ref)"
          refute_includes names1, "report_3_topics", "Should NOT match report with 3 topics"
          refute_includes names1, "report_2_topics_other", "Should NOT match report from other project"

          count1 = ReportTest210.query(project: project, :topics.size => 2).count
          puts "Count: #{count1}, all.count: #{results1.count}"
          assert_equal results1.count, count1, "count should match all.count"

          puts "✅ size + pointer constraint works!"

          # Test: size with pointer AND date constraint
          puts "\n--- Test: size + pointer + date constraint ---"
          results2 = ReportTest210.query(
            project: project,
            :topics.size => 2,
            :created_at.lt => reference_time,
          ).all
          names2 = results2.map(&:name).sort
          puts "Query: project=#{project.id}, :topics.size => 2, :created_at.lt => #{reference_time}"
          puts "Results: #{names2.inspect}"

          assert_includes names2, "report_2_topics", "Should match report with 2 topics before ref time"
          refute_includes names2, "report_2_topics_after", "Should NOT match report created after ref time"

          count2 = ReportTest210.query(
            project: project,
            :topics.size => 2,
            :created_at.lt => reference_time,
          ).count
          puts "Count: #{count2}, all.count: #{results2.count}"
          assert_equal results2.count, count2, "count should match all.count for pointer+date+size"

          puts "✅ size + pointer + date constraint works!"
        rescue => e
          puts "❌ Test failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(10).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 12: :arr_empty and :arr_nempty with pointer constraints and date constraints
  # ==========================================================================
  def test_arr_empty_with_pointer_and_date_constraints
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      puts "\n=== Testing :arr_empty and :arr_nempty with Pointer + Date Constraints ==="

      project = nil
      reference_time = nil

      with_timeout(15, "creating test data with varied topic states") do
        # Create parent object
        project = ProjectTest210.new(name: "Empty Array Project")
        project.save
        puts "Created project: #{project.id}"

        sleep(0.3)

        # Create reports with different topic states
        r0 = ReportTest210.new(name: "report_empty_topics", project: project, status: "pending", topics: [])
        r0.save
        puts "r0 (empty topics) id=#{r0.id}"

        r1 = ReportTest210.new(name: "report_with_topics", project: project, status: "pending", topics: ["A", "B"])
        r1.save
        puts "r1 (with topics) id=#{r1.id}"

        # Capture reference time
        sleep(0.3)
        reference_time = Time.now.utc
        puts "Reference time: #{reference_time}"
        sleep(0.3)

        r2 = ReportTest210.new(name: "report_empty_after", project: project, status: "pending", topics: [])
        r2.save
        puts "r2 (empty, after ref) id=#{r2.id}"

        r3 = ReportTest210.new(name: "report_with_topics_after", project: project, status: "pending", topics: ["C"])
        r3.save
        puts "r3 (with topics, after ref) id=#{r3.id}"

        # Different project
        other_project = ProjectTest210.new(name: "Other Empty Project")
        other_project.save
        rx = ReportTest210.new(name: "report_empty_other", project: other_project, status: "pending", topics: [])
        rx.save
        puts "rx (empty, other project) id=#{rx.id}"
      end

      with_timeout(20, "testing arr_empty/arr_nempty with pointer + date constraints") do
        begin
          # Test arr_empty with pointer constraint
          puts "\n--- Test: arr_empty + pointer constraint ---"
          results_empty = ReportTest210.query(
            project: project,
            :topics.arr_empty => true,
          ).all
          names_empty = results_empty.map(&:name).sort
          puts "Query: project=#{project.id}, :topics.arr_empty => true"
          puts "Results: #{names_empty.inspect}"

          assert_includes names_empty, "report_empty_topics", "Should match report with empty topics"
          assert_includes names_empty, "report_empty_after", "Should match report with empty topics (after ref)"
          refute_includes names_empty, "report_with_topics", "Should NOT match report with topics"
          refute_includes names_empty, "report_empty_other", "Should NOT match other project"

          count_empty = ReportTest210.query(project: project, :topics.arr_empty => true).count
          puts "Count: #{count_empty}, all.count: #{results_empty.count}"
          assert_equal results_empty.count, count_empty, "count should match all.count for arr_empty"

          puts "✅ arr_empty + pointer works!"

          # Test arr_empty with date constraint
          puts "\n--- Test: arr_empty + pointer + date constraint ---"
          results_empty_date = ReportTest210.query(
            project: project,
            :topics.arr_empty => true,
            :created_at.lt => reference_time,
          ).all
          names_empty_date = results_empty_date.map(&:name).sort
          puts "Query: project=#{project.id}, :topics.arr_empty => true, :created_at.lt => #{reference_time}"
          puts "Results: #{names_empty_date.inspect}"

          assert_includes names_empty_date, "report_empty_topics", "Should match report with empty topics before ref time"
          refute_includes names_empty_date, "report_empty_after", "Should NOT match report created after ref time"

          count_empty_date = ReportTest210.query(
            project: project,
            :topics.arr_empty => true,
            :created_at.lt => reference_time,
          ).count
          puts "Count: #{count_empty_date}"
          assert_equal results_empty_date.count, count_empty_date, "count should match for arr_empty+date"

          puts "✅ arr_empty + pointer + date works!"

          # Test arr_nempty (not empty) with pointer constraint
          puts "\n--- Test: arr_nempty + pointer constraint ---"
          results_nempty = ReportTest210.query(
            project: project,
            :topics.arr_nempty => true,
          ).all
          names_nempty = results_nempty.map(&:name).sort
          puts "Query: project=#{project.id}, :topics.arr_nempty => true"
          puts "Results: #{names_nempty.inspect}"

          assert_includes names_nempty, "report_with_topics", "Should match report with topics"
          assert_includes names_nempty, "report_with_topics_after", "Should match report with topics (after ref)"
          refute_includes names_nempty, "report_empty_topics", "Should NOT match report with empty topics"

          count_nempty = ReportTest210.query(project: project, :topics.arr_nempty => true).count
          puts "Count: #{count_nempty}, all.count: #{results_nempty.count}"
          assert_equal results_nempty.count, count_nempty, "count should match all.count for arr_nempty"

          puts "✅ arr_nempty + pointer works!"

          # Test arr_nempty with date constraint
          puts "\n--- Test: arr_nempty + pointer + date constraint ---"
          results_nempty_date = ReportTest210.query(
            project: project,
            :topics.arr_nempty => true,
            :created_at.lt => reference_time,
          ).all
          names_nempty_date = results_nempty_date.map(&:name).sort
          puts "Query: project=#{project.id}, :topics.arr_nempty => true, :created_at.lt => #{reference_time}"
          puts "Results: #{names_nempty_date.inspect}"

          assert_includes names_nempty_date, "report_with_topics", "Should match report with topics before ref time"
          refute_includes names_nempty_date, "report_with_topics_after", "Should NOT match report created after ref time"

          count_nempty_date = ReportTest210.query(
            project: project,
            :topics.arr_nempty => true,
            :created_at.lt => reference_time,
          ).count
          puts "Count: #{count_nempty_date}"
          assert_equal results_nempty_date.count, count_nempty_date, "count should match for arr_nempty+date"

          puts "✅ arr_nempty + pointer + date works!"

          puts "\n✅ All arr_empty/arr_nempty tests with pointer + date passed!"
        rescue => e
          puts "❌ Test failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(10).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 13: :set_equals, :eq_array, :not_set_equals with pointer + date constraints
  # ==========================================================================
  def test_set_equals_with_pointer_and_date_constraints
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      puts "\n=== Testing :set_equals with Pointer + Date Constraints ==="

      project = nil
      reference_time = nil

      with_timeout(15, "creating test data for set_equals tests") do
        # Create parent object
        project = ProjectTest210.new(name: "Set Equals Project")
        project.save
        puts "Created project: #{project.id}"

        sleep(0.3)

        # Create reports with different topic arrays
        r1 = ReportTest210.new(name: "report_AB", project: project, status: "pending", topics: ["A", "B"])
        r1.save
        puts "r1 (A, B) id=#{r1.id}"

        r2 = ReportTest210.new(name: "report_BA", project: project, status: "pending", topics: ["B", "A"])
        r2.save
        puts "r2 (B, A) - same as r1 but different order, id=#{r2.id}"

        r3 = ReportTest210.new(name: "report_ABC", project: project, status: "pending", topics: ["A", "B", "C"])
        r3.save
        puts "r3 (A, B, C) id=#{r3.id}"

        # Capture reference time
        sleep(0.3)
        reference_time = Time.now.utc
        puts "Reference time: #{reference_time}"
        sleep(0.3)

        r4 = ReportTest210.new(name: "report_AB_after", project: project, status: "pending", topics: ["A", "B"])
        r4.save
        puts "r4 (A, B, after ref) id=#{r4.id}"

        r5 = ReportTest210.new(name: "report_XY", project: project, status: "pending", topics: ["X", "Y"])
        r5.save
        puts "r5 (X, Y, after ref) id=#{r5.id}"

        # Different project
        other_project = ProjectTest210.new(name: "Other Set Project")
        other_project.save
        rx = ReportTest210.new(name: "report_AB_other", project: other_project, status: "pending", topics: ["A", "B"])
        rx.save
        puts "rx (A, B, other project) id=#{rx.id}"
      end

      with_timeout(20, "testing set_equals/eq_array with pointer + date constraints") do
        begin
          # Test set_equals (order independent) with pointer constraint
          puts "\n--- Test: set_equals + pointer constraint ---"
          results_set = ReportTest210.query(
            project: project,
            :topics.set_equals => ["B", "A"], # Should match ["A", "B"] and ["B", "A"]
          ).all
          names_set = results_set.map(&:name).sort
          puts "Query: project=#{project.id}, :topics.set_equals => ['B', 'A']"
          puts "Results: #{names_set.inspect}"

          assert_includes names_set, "report_AB", "set_equals should match A,B"
          assert_includes names_set, "report_BA", "set_equals should match B,A (order independent)"
          assert_includes names_set, "report_AB_after", "set_equals should match A,B after ref"
          refute_includes names_set, "report_ABC", "set_equals should NOT match A,B,C (different elements)"
          refute_includes names_set, "report_AB_other", "set_equals should NOT match other project"

          count_set = ReportTest210.query(project: project, :topics.set_equals => ["B", "A"]).count
          puts "Count: #{count_set}, all.count: #{results_set.count}"
          assert_equal results_set.count, count_set, "count should match all.count for set_equals"

          puts "✅ set_equals + pointer works!"

          # Test set_equals with date constraint
          puts "\n--- Test: set_equals + pointer + date constraint ---"
          results_set_date = ReportTest210.query(
            project: project,
            :topics.set_equals => ["A", "B"],
            :created_at.lt => reference_time,
          ).all
          names_set_date = results_set_date.map(&:name).sort
          puts "Query: project=#{project.id}, :topics.set_equals => ['A', 'B'], :created_at.lt => #{reference_time}"
          puts "Results: #{names_set_date.inspect}"

          assert_includes names_set_date, "report_AB", "Should match report_AB before ref time"
          assert_includes names_set_date, "report_BA", "Should match report_BA before ref time"
          refute_includes names_set_date, "report_AB_after", "Should NOT match report created after ref time"

          count_set_date = ReportTest210.query(
            project: project,
            :topics.set_equals => ["A", "B"],
            :created_at.lt => reference_time,
          ).count
          puts "Count: #{count_set_date}"
          assert_equal results_set_date.count, count_set_date, "count should match for set_equals+date"

          puts "✅ set_equals + pointer + date works!"

          # Test not_set_equals with pointer constraint
          puts "\n--- Test: not_set_equals + pointer constraint ---"
          results_not_set = ReportTest210.query(
            project: project,
            :topics.not_set_equals => ["A", "B"], # Should NOT match ["A", "B"] or ["B", "A"]
          ).all
          names_not_set = results_not_set.map(&:name).sort
          puts "Query: project=#{project.id}, :topics.not_set_equals => ['A', 'B']"
          puts "Results: #{names_not_set.inspect}"

          refute_includes names_not_set, "report_AB", "not_set_equals should NOT match A,B"
          refute_includes names_not_set, "report_BA", "not_set_equals should NOT match B,A"
          refute_includes names_not_set, "report_AB_after", "not_set_equals should NOT match A,B after"
          assert_includes names_not_set, "report_ABC", "not_set_equals should match A,B,C"
          assert_includes names_not_set, "report_XY", "not_set_equals should match X,Y"

          count_not_set = ReportTest210.query(project: project, :topics.not_set_equals => ["A", "B"]).count
          puts "Count: #{count_not_set}, all.count: #{results_not_set.count}"
          assert_equal results_not_set.count, count_not_set, "count should match all.count for not_set_equals"

          puts "✅ not_set_equals + pointer works!"

          # Test not_set_equals with date constraint
          puts "\n--- Test: not_set_equals + pointer + date constraint ---"
          results_not_set_date = ReportTest210.query(
            project: project,
            :topics.not_set_equals => ["A", "B"],
            :created_at.lt => reference_time,
          ).all
          names_not_set_date = results_not_set_date.map(&:name).sort
          puts "Query: project=#{project.id}, :topics.not_set_equals => ['A', 'B'], :created_at.lt => #{reference_time}"
          puts "Results: #{names_not_set_date.inspect}"

          assert_includes names_not_set_date, "report_ABC", "Should match report_ABC before ref time"
          refute_includes names_not_set_date, "report_AB", "Should NOT match report_AB"
          refute_includes names_not_set_date, "report_XY", "Should NOT match report_XY (after ref time)"

          count_not_set_date = ReportTest210.query(
            project: project,
            :topics.not_set_equals => ["A", "B"],
            :created_at.lt => reference_time,
          ).count
          puts "Count: #{count_not_set_date}"
          assert_equal results_not_set_date.count, count_not_set_date, "count should match for not_set_equals+date"

          puts "✅ not_set_equals + pointer + date works!"

          puts "\n✅ All set_equals/not_set_equals tests with pointer + date passed!"
        rescue => e
          puts "❌ Test failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(10).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 14: :eq_array (order dependent) with pointer + date constraints
  # ==========================================================================
  def test_eq_array_with_pointer_and_date_constraints
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      puts "\n=== Testing :eq_array with Pointer + Date Constraints ==="

      project = nil
      reference_time = nil

      with_timeout(15, "creating test data for eq_array tests") do
        # Create parent object
        project = ProjectTest210.new(name: "Eq Array Project")
        project.save
        puts "Created project: #{project.id}"

        sleep(0.3)

        # Create reports with different topic arrays - order matters for eq_array
        r1 = ReportTest210.new(name: "report_AB", project: project, status: "pending", topics: ["A", "B"])
        r1.save
        puts "r1 (A, B) id=#{r1.id}"

        r2 = ReportTest210.new(name: "report_BA", project: project, status: "pending", topics: ["B", "A"])
        r2.save
        puts "r2 (B, A) - different order, id=#{r2.id}"

        r3 = ReportTest210.new(name: "report_AB_dup", project: project, status: "pending", topics: ["A", "B"])
        r3.save
        puts "r3 (A, B) - duplicate, id=#{r3.id}"

        # Capture reference time
        sleep(0.3)
        reference_time = Time.now.utc
        puts "Reference time: #{reference_time}"
        sleep(0.3)

        r4 = ReportTest210.new(name: "report_AB_after", project: project, status: "pending", topics: ["A", "B"])
        r4.save
        puts "r4 (A, B, after ref) id=#{r4.id}"

        # Different project
        other_project = ProjectTest210.new(name: "Other Eq Array Project")
        other_project.save
        rx = ReportTest210.new(name: "report_AB_other", project: other_project, status: "pending", topics: ["A", "B"])
        rx.save
        puts "rx (A, B, other project) id=#{rx.id}"
      end

      with_timeout(20, "testing eq_array with pointer + date constraints") do
        begin
          # Test eq_array (order dependent) with pointer constraint
          puts "\n--- Test: eq_array + pointer constraint ---"
          results_eq = ReportTest210.query(
            project: project,
            :topics.eq_array => ["A", "B"], # Order matters - should only match ["A", "B"]
          ).all
          names_eq = results_eq.map(&:name).sort
          puts "Query: project=#{project.id}, :topics.eq_array => ['A', 'B']"
          puts "Results: #{names_eq.inspect}"

          assert_includes names_eq, "report_AB", "eq_array should match A,B"
          assert_includes names_eq, "report_AB_dup", "eq_array should match duplicate A,B"
          assert_includes names_eq, "report_AB_after", "eq_array should match A,B after ref"
          refute_includes names_eq, "report_BA", "eq_array should NOT match B,A (order matters)"
          refute_includes names_eq, "report_AB_other", "eq_array should NOT match other project"

          count_eq = ReportTest210.query(project: project, :topics.eq_array => ["A", "B"]).count
          puts "Count: #{count_eq}, all.count: #{results_eq.count}"
          assert_equal results_eq.count, count_eq, "count should match all.count for eq_array"

          puts "✅ eq_array + pointer works!"

          # Test eq_array with date constraint
          puts "\n--- Test: eq_array + pointer + date constraint ---"
          results_eq_date = ReportTest210.query(
            project: project,
            :topics.eq_array => ["A", "B"],
            :created_at.lt => reference_time,
          ).all
          names_eq_date = results_eq_date.map(&:name).sort
          puts "Query: project=#{project.id}, :topics.eq_array => ['A', 'B'], :created_at.lt => #{reference_time}"
          puts "Results: #{names_eq_date.inspect}"

          assert_includes names_eq_date, "report_AB", "Should match report_AB before ref time"
          assert_includes names_eq_date, "report_AB_dup", "Should match report_AB_dup before ref time"
          refute_includes names_eq_date, "report_AB_after", "Should NOT match report created after ref time"
          refute_includes names_eq_date, "report_BA", "Should NOT match B,A (order matters)"

          count_eq_date = ReportTest210.query(
            project: project,
            :topics.eq_array => ["A", "B"],
            :created_at.lt => reference_time,
          ).count
          puts "Count: #{count_eq_date}"
          assert_equal results_eq_date.count, count_eq_date, "count should match for eq_array+date"

          puts "✅ eq_array + pointer + date works!"

          puts "\n✅ All eq_array tests with pointer + date passed!"
        rescue => e
          puts "❌ Test failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(10).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 15: group_by aggregation with pointer + date + array constraints
  # ==========================================================================
  def test_group_by_with_pointer_and_array_constraints
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      puts "\n=== Testing group_by with Pointer + Array Constraints ==="

      project = nil
      reference_time = nil

      with_timeout(15, "creating test data for group_by tests") do
        # Create parent object
        project = ProjectTest210.new(name: "Group By Project")
        project.save
        puts "Created project: #{project.id}"

        sleep(0.3)

        # Create reports with different statuses and topic states
        r1 = ReportTest210.new(name: "report_pending_empty", project: project, status: "pending", topics: [])
        r1.save
        puts "r1 (pending, empty) id=#{r1.id}"

        r2 = ReportTest210.new(name: "report_pending_topics", project: project, status: "pending", topics: ["A", "B"])
        r2.save
        puts "r2 (pending, has topics) id=#{r2.id}"

        r3 = ReportTest210.new(name: "report_complete_empty", project: project, status: "complete", topics: [])
        r3.save
        puts "r3 (complete, empty) id=#{r3.id}"

        # Capture reference time
        sleep(0.3)
        reference_time = Time.now.utc
        puts "Reference time: #{reference_time}"
        sleep(0.3)

        r4 = ReportTest210.new(name: "report_pending_empty_after", project: project, status: "pending", topics: [])
        r4.save
        puts "r4 (pending, empty, after ref) id=#{r4.id}"

        r5 = ReportTest210.new(name: "report_complete_topics_after", project: project, status: "complete", topics: ["C"])
        r5.save
        puts "r5 (complete, has topics, after ref) id=#{r5.id}"

        # Different project
        other_project = ProjectTest210.new(name: "Other Group By Project")
        other_project.save
        rx = ReportTest210.new(name: "report_other_pending", project: other_project, status: "pending", topics: [])
        rx.save
        puts "rx (other project, pending, empty) id=#{rx.id}"
      end

      with_timeout(20, "testing group_by with pointer + array constraints") do
        begin
          # Test group_by status with pointer constraint only
          puts "\n--- Test: group_by status + pointer constraint ---"
          query1 = ReportTest210.query(project: project)
          results_by_status = query1.group_by(:status).count
          puts "Query: project=#{project.id}, group_by(:status).count"
          puts "Results: #{results_by_status.inspect}"

          # Should have both pending and complete statuses
          assert results_by_status.key?("pending"), "Should have pending status"
          assert results_by_status.key?("complete"), "Should have complete status"
          assert_equal 3, results_by_status["pending"], "Should have 3 pending reports"
          assert_equal 2, results_by_status["complete"], "Should have 2 complete reports"

          puts "✅ group_by status + pointer works!"

          # Test group_by with pointer + empty_or_nil constraint
          puts "\n--- Test: group_by status + pointer + empty_or_nil ---"
          query2 = ReportTest210.query(
            project: project,
            :topics.empty_or_nil => true,
          )
          results_empty = query2.group_by(:status).count
          puts "Query: project=#{project.id}, :topics.empty_or_nil => true, group_by(:status).count"
          puts "Results: #{results_empty.inspect}"

          # Should only count reports with empty topics
          assert results_empty.key?("pending"), "Should have pending status"
          assert results_empty.key?("complete"), "Should have complete status"
          assert_equal 2, results_empty["pending"], "Should have 2 pending reports with empty topics"
          assert_equal 1, results_empty["complete"], "Should have 1 complete report with empty topics"

          puts "✅ group_by status + pointer + empty_or_nil works!"

          # Test group_by with pointer + empty_or_nil + date constraint
          puts "\n--- Test: group_by status + pointer + empty_or_nil + date ---"
          query3 = ReportTest210.query(
            project: project,
            :topics.empty_or_nil => true,
            :created_at.lt => reference_time,
          )
          results_empty_date = query3.group_by(:status).count
          puts "Query: project=#{project.id}, :topics.empty_or_nil => true, :created_at.lt => #{reference_time}, group_by(:status).count"
          puts "Results: #{results_empty_date.inspect}"

          # Should only count reports with empty topics before reference time
          assert results_empty_date.key?("pending"), "Should have pending status"
          assert results_empty_date.key?("complete"), "Should have complete status"
          assert_equal 1, results_empty_date["pending"], "Should have 1 pending report with empty topics before ref"
          assert_equal 1, results_empty_date["complete"], "Should have 1 complete report with empty topics before ref"

          puts "✅ group_by status + pointer + empty_or_nil + date works!"

          # Test sum aggregation with pointer + array constraint
          puts "\n--- Test: sum with pointer + empty_or_nil constraint ---"
          # We don't have a numeric field to sum, so we'll just verify the query works
          # by using count_distinct instead
          query4 = ReportTest210.query(
            project: project,
            :topics.empty_or_nil => true,
          )
          distinct_count = query4.count_distinct(:status)
          puts "Query: project=#{project.id}, :topics.empty_or_nil => true, count_distinct(:status)"
          puts "Distinct statuses: #{distinct_count}"

          assert_equal 2, distinct_count, "Should have 2 distinct statuses (pending, complete)"

          puts "✅ count_distinct + pointer + empty_or_nil works!"

          puts "\n✅ All group_by tests with pointer + array constraints passed!"
        rescue => e
          puts "❌ Test failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(10).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Tests for arrays of pointers (has_many through: :array)
  # ==========================================================================

  # Test models for array of pointers
  class MemberTest210 < Parse::Object
    parse_class "MemberTest210"
    property :name, :string
    property :role, :string
  end

  class TeamWithMembers210 < Parse::Object
    parse_class "TeamWithMembers210"
    property :name, :string
    property :status, :string
    has_many :members, as: :member_test210, through: :array
    belongs_to :project, as: :project_test210
  end

  # ==========================================================================
  # Test 16: Array of pointers - :size constraint
  # ==========================================================================
  def test_pointer_array_size_constraint
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      puts "\n=== Testing :size with Array of Pointers ==="

      project = nil
      members = []

      with_timeout(15, "creating test data with pointer arrays") do
        # Create project
        project = ProjectTest210.new(name: "Pointer Array Project")
        project.save
        puts "Created project: #{project.id}"

        # Create members
        3.times do |i|
          member = MemberTest210.new(name: "Member #{i + 1}", role: i.even? ? "developer" : "designer")
          member.save
          members << member
          puts "Created member: #{member.id} - #{member.name}"
        end

        sleep(0.3)

        # Create teams with different member counts
        t1 = TeamWithMembers210.new(name: "team_2_members", project: project, status: "active", members: [members[0], members[1]])
        t1.save
        puts "t1 (2 members) id=#{t1.id}"

        t2 = TeamWithMembers210.new(name: "team_3_members", project: project, status: "active", members: members)
        t2.save
        puts "t2 (3 members) id=#{t2.id}"

        t3 = TeamWithMembers210.new(name: "team_1_member", project: project, status: "inactive", members: [members[0]])
        t3.save
        puts "t3 (1 member) id=#{t3.id}"

        t4 = TeamWithMembers210.new(name: "team_no_members", project: project, status: "active", members: [])
        t4.save
        puts "t4 (0 members) id=#{t4.id}"

        # Different project
        other_project = ProjectTest210.new(name: "Other Pointer Array Project")
        other_project.save
        tx = TeamWithMembers210.new(name: "team_other_project", project: other_project, status: "active", members: [members[0], members[1]])
        tx.save
        puts "tx (other project, 2 members) id=#{tx.id}"
      end

      with_timeout(20, "testing :size with pointer arrays") do
        begin
          # Test size = 2 with project filter
          puts "\n--- Test: size(2) + project constraint ---"
          results = TeamWithMembers210.query(
            project: project,
            :members.size => 2,
          ).all
          names = results.map(&:name).sort
          puts "Query: project=#{project.id}, :members.size => 2"
          puts "Results: #{names.inspect}"

          assert_includes names, "team_2_members", "Should match team with 2 members"
          refute_includes names, "team_3_members", "Should NOT match team with 3 members"
          refute_includes names, "team_1_member", "Should NOT match team with 1 member"
          refute_includes names, "team_other_project", "Should NOT match other project"

          count = TeamWithMembers210.query(project: project, :members.size => 2).count
          puts "Count: #{count}"
          assert_equal results.count, count, "count should match all.count"

          puts "✅ size(2) + project works for pointer arrays!"

          # Test size = 0 (empty array)
          puts "\n--- Test: size(0) + project constraint ---"
          results_empty = TeamWithMembers210.query(
            project: project,
            :members.size => 0,
          ).all
          names_empty = results_empty.map(&:name).sort
          puts "Query: project=#{project.id}, :members.size => 0"
          puts "Results: #{names_empty.inspect}"

          assert_includes names_empty, "team_no_members", "Should match team with 0 members"
          assert_equal 1, results_empty.count, "Should have exactly 1 result"

          puts "✅ size(0) works for pointer arrays!"
        rescue => e
          puts "❌ Test failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(10).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 17: Array of pointers - :empty_or_nil and :arr_empty constraints
  # ==========================================================================
  def test_pointer_array_empty_constraints
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      puts "\n=== Testing :empty_or_nil with Array of Pointers ==="

      project = nil
      members = []

      with_timeout(15, "creating test data with pointer arrays") do
        # Create project
        project = ProjectTest210.new(name: "Empty Pointer Array Project")
        project.save
        puts "Created project: #{project.id}"

        # Create members
        2.times do |i|
          member = MemberTest210.new(name: "Member #{i + 1}", role: "developer")
          member.save
          members << member
        end

        sleep(0.3)

        # Teams with different member states
        t1 = TeamWithMembers210.new(name: "team_with_members", project: project, status: "active", members: members)
        t1.save
        puts "t1 (has members) id=#{t1.id}"

        t2 = TeamWithMembers210.new(name: "team_empty_members", project: project, status: "active", members: [])
        t2.save
        puts "t2 (empty members) id=#{t2.id}"

        t3 = TeamWithMembers210.new(name: "team_nil_members", project: project, status: "inactive")
        t3.save
        puts "t3 (nil/unset members) id=#{t3.id}"

        # Different project
        other_project = ProjectTest210.new(name: "Other Empty Pointer Project")
        other_project.save
        tx = TeamWithMembers210.new(name: "team_empty_other", project: other_project, status: "active", members: [])
        tx.save
        puts "tx (other project, empty) id=#{tx.id}"
      end

      with_timeout(20, "testing empty_or_nil with pointer arrays") do
        begin
          # Test empty_or_nil with project filter
          puts "\n--- Test: empty_or_nil + project constraint ---"
          results = TeamWithMembers210.query(
            project: project,
            :members.empty_or_nil => true,
          ).all
          names = results.map(&:name).sort
          puts "Query: project=#{project.id}, :members.empty_or_nil => true"
          puts "Results: #{names.inspect}"

          assert_includes names, "team_empty_members", "Should match team with empty members"
          assert_includes names, "team_nil_members", "Should match team with nil members"
          refute_includes names, "team_with_members", "Should NOT match team with members"
          refute_includes names, "team_empty_other", "Should NOT match other project"

          count = TeamWithMembers210.query(project: project, :members.empty_or_nil => true).count
          puts "Count: #{count}"
          assert_equal results.count, count, "count should match all.count"

          puts "✅ empty_or_nil works for pointer arrays!"

          # Test arr_empty (only matches explicitly empty, not nil)
          puts "\n--- Test: arr_empty + project constraint ---"
          results_empty = TeamWithMembers210.query(
            project: project,
            :members.arr_empty => true,
          ).all
          names_empty = results_empty.map(&:name).sort
          puts "Query: project=#{project.id}, :members.arr_empty => true"
          puts "Results: #{names_empty.inspect}"

          assert_includes names_empty, "team_empty_members", "Should match team with empty members"
          # Note: arr_empty should match [] but not nil/undefined

          count_empty = TeamWithMembers210.query(project: project, :members.arr_empty => true).count
          puts "Count: #{count_empty}"
          assert_equal results_empty.count, count_empty, "count should match all.count"

          puts "✅ arr_empty works for pointer arrays!"

          # Test not_empty (has at least one member)
          puts "\n--- Test: not_empty + project constraint ---"
          results_not_empty = TeamWithMembers210.query(
            project: project,
            :members.not_empty => true,
          ).all
          names_not_empty = results_not_empty.map(&:name).sort
          puts "Query: project=#{project.id}, :members.not_empty => true"
          puts "Results: #{names_not_empty.inspect}"

          assert_includes names_not_empty, "team_with_members", "Should match team with members"
          refute_includes names_not_empty, "team_empty_members", "Should NOT match empty team"
          refute_includes names_not_empty, "team_nil_members", "Should NOT match nil team"

          puts "✅ not_empty works for pointer arrays!"
        rescue => e
          puts "❌ Test failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(10).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 18: Array of pointers - :contains_all constraint
  # ==========================================================================
  def test_pointer_array_contains_all_constraint
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      puts "\n=== Testing :contains_all with Array of Pointers ==="

      project = nil
      members = []

      with_timeout(15, "creating test data with pointer arrays") do
        # Create project
        project = ProjectTest210.new(name: "Contains All Project")
        project.save
        puts "Created project: #{project.id}"

        # Create 4 members
        4.times do |i|
          member = MemberTest210.new(name: "Member #{i + 1}", role: i.even? ? "developer" : "designer")
          member.save
          members << member
          puts "Created member: #{member.id} - #{member.name}"
        end

        sleep(0.3)

        # Teams with different combinations
        t1 = TeamWithMembers210.new(name: "team_all_4", project: project, status: "active", members: members)
        t1.save
        puts "t1 (all 4 members) id=#{t1.id}"

        t2 = TeamWithMembers210.new(name: "team_first_2", project: project, status: "active", members: [members[0], members[1]])
        t2.save
        puts "t2 (members 1,2) id=#{t2.id}"

        t3 = TeamWithMembers210.new(name: "team_last_2", project: project, status: "active", members: [members[2], members[3]])
        t3.save
        puts "t3 (members 3,4) id=#{t3.id}"

        t4 = TeamWithMembers210.new(name: "team_1_and_3", project: project, status: "inactive", members: [members[0], members[2]])
        t4.save
        puts "t4 (members 1,3) id=#{t4.id}"
      end

      with_timeout(20, "testing contains_all with pointer arrays") do
        begin
          # Test contains_all with single member
          puts "\n--- Test: contains_all([member1]) + project ---"
          results_one = TeamWithMembers210.query(
            project: project,
            :members.contains_all => [members[0]],
          ).all
          names_one = results_one.map(&:name).sort
          puts "Query: project=#{project.id}, :members.contains_all => [member1]"
          puts "Results: #{names_one.inspect}"

          assert_includes names_one, "team_all_4", "Should match team with all members"
          assert_includes names_one, "team_first_2", "Should match team with member 1"
          assert_includes names_one, "team_1_and_3", "Should match team with members 1,3"
          refute_includes names_one, "team_last_2", "Should NOT match team without member 1"

          count_one = TeamWithMembers210.query(project: project, :members.contains_all => [members[0]]).count
          puts "Count: #{count_one}"
          assert_equal results_one.count, count_one

          puts "✅ contains_all([single]) works for pointer arrays!"

          # Test contains_all with multiple members
          puts "\n--- Test: contains_all([member1, member2]) + project ---"
          results_two = TeamWithMembers210.query(
            project: project,
            :members.contains_all => [members[0], members[1]],
          ).all
          names_two = results_two.map(&:name).sort
          puts "Query: project=#{project.id}, :members.contains_all => [member1, member2]"
          puts "Results: #{names_two.inspect}"

          assert_includes names_two, "team_all_4", "Should match team with all members"
          assert_includes names_two, "team_first_2", "Should match team with members 1,2"
          refute_includes names_two, "team_1_and_3", "Should NOT match team with only 1,3"
          refute_includes names_two, "team_last_2", "Should NOT match team with 3,4"

          count_two = TeamWithMembers210.query(project: project, :members.contains_all => [members[0], members[1]]).count
          puts "Count: #{count_two}"
          assert_equal results_two.count, count_two

          puts "✅ contains_all([multiple]) works for pointer arrays!"
        rescue => e
          puts "❌ Test failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(10).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 19: Array of pointers - :any (contains any) constraint
  # ==========================================================================
  def test_pointer_array_any_constraint
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      puts "\n=== Testing :any with Array of Pointers ==="

      project = nil
      members = []

      with_timeout(15, "creating test data with pointer arrays") do
        # Create project
        project = ProjectTest210.new(name: "Any Pointer Project")
        project.save
        puts "Created project: #{project.id}"

        # Create 4 members
        4.times do |i|
          member = MemberTest210.new(name: "Member #{i + 1}", role: "developer")
          member.save
          members << member
          puts "Created member: #{member.id} - #{member.name}"
        end

        sleep(0.3)

        # Teams with different combinations
        t1 = TeamWithMembers210.new(name: "team_1_only", project: project, status: "active", members: [members[0]])
        t1.save
        puts "t1 (member 1 only) id=#{t1.id}"

        t2 = TeamWithMembers210.new(name: "team_2_only", project: project, status: "active", members: [members[1]])
        t2.save
        puts "t2 (member 2 only) id=#{t2.id}"

        t3 = TeamWithMembers210.new(name: "team_3_and_4", project: project, status: "active", members: [members[2], members[3]])
        t3.save
        puts "t3 (members 3,4) id=#{t3.id}"

        t4 = TeamWithMembers210.new(name: "team_empty", project: project, status: "inactive", members: [])
        t4.save
        puts "t4 (empty) id=#{t4.id}"
      end

      with_timeout(20, "testing :any with pointer arrays") do
        begin
          # Test any with two members (should match teams with either)
          puts "\n--- Test: any([member1, member2]) + project ---"
          results = TeamWithMembers210.query(
            project: project,
            :members.any => [members[0], members[1]],
          ).all
          names = results.map(&:name).sort
          puts "Query: project=#{project.id}, :members.any => [member1, member2]"
          puts "Results: #{names.inspect}"

          assert_includes names, "team_1_only", "Should match team with member 1"
          assert_includes names, "team_2_only", "Should match team with member 2"
          refute_includes names, "team_3_and_4", "Should NOT match team with only 3,4"
          refute_includes names, "team_empty", "Should NOT match empty team"

          count = TeamWithMembers210.query(project: project, :members.any => [members[0], members[1]]).count
          puts "Count: #{count}"
          assert_equal results.count, count

          puts "✅ any works for pointer arrays!"
        rescue => e
          puts "❌ Test failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(10).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 20: Array of pointers - :set_equals constraint (exact match, order independent)
  # ==========================================================================
  def test_pointer_array_set_equals_constraint
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      puts "\n=== Testing :set_equals with Array of Pointers ==="

      project = nil
      members = []

      with_timeout(15, "creating test data with pointer arrays") do
        # Create project
        project = ProjectTest210.new(name: "Set Equals Pointer Project")
        project.save
        puts "Created project: #{project.id}"

        # Create 3 members
        3.times do |i|
          member = MemberTest210.new(name: "Member #{i + 1}", role: "developer")
          member.save
          members << member
          puts "Created member: #{member.id} - #{member.name}"
        end

        sleep(0.3)

        # Teams with same members but different order, and different combinations
        t1 = TeamWithMembers210.new(name: "team_AB", project: project, status: "active", members: [members[0], members[1]])
        t1.save
        puts "t1 (A,B) id=#{t1.id}"

        t2 = TeamWithMembers210.new(name: "team_BA", project: project, status: "active", members: [members[1], members[0]])
        t2.save
        puts "t2 (B,A) - same as t1, different order, id=#{t2.id}"

        t3 = TeamWithMembers210.new(name: "team_ABC", project: project, status: "active", members: members)
        t3.save
        puts "t3 (A,B,C) id=#{t3.id}"

        t4 = TeamWithMembers210.new(name: "team_AC", project: project, status: "inactive", members: [members[0], members[2]])
        t4.save
        puts "t4 (A,C) id=#{t4.id}"
      end

      with_timeout(20, "testing set_equals with pointer arrays") do
        begin
          # Test set_equals - should match teams with exactly [A,B] in any order
          puts "\n--- Test: set_equals([A,B]) + project ---"
          results = TeamWithMembers210.query(
            project: project,
            :members.set_equals => [members[1], members[0]], # Pass in B,A order
          ).all
          names = results.map(&:name).sort
          puts "Query: project=#{project.id}, :members.set_equals => [B, A]"
          puts "Results: #{names.inspect}"

          assert_includes names, "team_AB", "Should match team with A,B"
          assert_includes names, "team_BA", "Should match team with B,A (order independent)"
          refute_includes names, "team_ABC", "Should NOT match team with A,B,C"
          refute_includes names, "team_AC", "Should NOT match team with A,C"

          count = TeamWithMembers210.query(project: project, :members.set_equals => [members[0], members[1]]).count
          puts "Count: #{count}"
          assert_equal results.count, count

          puts "✅ set_equals works for pointer arrays!"

          # Test not_set_equals
          puts "\n--- Test: not_set_equals([A,B]) + project ---"
          results_not = TeamWithMembers210.query(
            project: project,
            :members.not_set_equals => [members[0], members[1]],
          ).all
          names_not = results_not.map(&:name).sort
          puts "Query: project=#{project.id}, :members.not_set_equals => [A, B]"
          puts "Results: #{names_not.inspect}"

          refute_includes names_not, "team_AB", "Should NOT match team with A,B"
          refute_includes names_not, "team_BA", "Should NOT match team with B,A"
          assert_includes names_not, "team_ABC", "Should match team with A,B,C"
          assert_includes names_not, "team_AC", "Should match team with A,C"

          puts "✅ not_set_equals works for pointer arrays!"
        rescue => e
          puts "❌ Test failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(10).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 21: Combined - pointer array constraints with date and other pointer
  # ==========================================================================
  def test_pointer_array_with_date_and_pointer_constraints
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      puts "\n=== Testing Pointer Array + Date + Pointer Constraints ==="

      project = nil
      members = []
      reference_time = nil

      with_timeout(15, "creating test data") do
        # Create project
        project = ProjectTest210.new(name: "Combined Pointer Array Project")
        project.save
        puts "Created project: #{project.id}"

        # Create 2 members
        2.times do |i|
          member = MemberTest210.new(name: "Member #{i + 1}", role: "developer")
          member.save
          members << member
        end

        sleep(0.3)

        # Create teams with different states
        t1 = TeamWithMembers210.new(name: "team_empty_before", project: project, status: "active", members: [])
        t1.save
        puts "t1 (empty, before ref) id=#{t1.id}"

        t2 = TeamWithMembers210.new(name: "team_with_members_before", project: project, status: "active", members: members)
        t2.save
        puts "t2 (with members, before ref) id=#{t2.id}"

        # Capture reference time
        sleep(0.3)
        reference_time = Time.now.utc
        puts "Reference time: #{reference_time}"
        sleep(0.3)

        t3 = TeamWithMembers210.new(name: "team_empty_after", project: project, status: "active", members: [])
        t3.save
        puts "t3 (empty, after ref) id=#{t3.id}"

        t4 = TeamWithMembers210.new(name: "team_with_members_after", project: project, status: "inactive", members: [members[0]])
        t4.save
        puts "t4 (1 member, after ref) id=#{t4.id}"

        # Different project
        other_project = ProjectTest210.new(name: "Other Combined Project")
        other_project.save
        tx = TeamWithMembers210.new(name: "team_other", project: other_project, status: "active", members: [])
        tx.save
        puts "tx (other project) id=#{tx.id}"
      end

      with_timeout(20, "testing combined constraints") do
        begin
          # Test empty_or_nil + project + date
          puts "\n--- Test: empty_or_nil + project + date ---"
          results = TeamWithMembers210.query(
            project: project,
            :members.empty_or_nil => true,
            :created_at.lt => reference_time,
          ).all
          names = results.map(&:name).sort
          puts "Query: project, :members.empty_or_nil => true, :created_at.lt => ref"
          puts "Results: #{names.inspect}"

          assert_includes names, "team_empty_before", "Should match empty team before ref"
          refute_includes names, "team_empty_after", "Should NOT match empty team after ref"
          refute_includes names, "team_with_members_before", "Should NOT match team with members"
          refute_includes names, "team_other", "Should NOT match other project"

          count = TeamWithMembers210.query(
            project: project,
            :members.empty_or_nil => true,
            :created_at.lt => reference_time,
          ).count
          puts "Count: #{count}"
          assert_equal results.count, count

          puts "✅ empty_or_nil + project + date works for pointer arrays!"

          # Test not_empty + project + date
          puts "\n--- Test: not_empty + project + date ---"
          results_ne = TeamWithMembers210.query(
            project: project,
            :members.not_empty => true,
            :created_at.lt => reference_time,
          ).all
          names_ne = results_ne.map(&:name).sort
          puts "Query: project, :members.not_empty => true, :created_at.lt => ref"
          puts "Results: #{names_ne.inspect}"

          assert_includes names_ne, "team_with_members_before", "Should match team with members before ref"
          refute_includes names_ne, "team_with_members_after", "Should NOT match team after ref"
          refute_includes names_ne, "team_empty_before", "Should NOT match empty team"

          puts "✅ not_empty + project + date works for pointer arrays!"

          # Test group_by with pointer array constraints
          puts "\n--- Test: group_by + empty_or_nil ---"
          results_group = TeamWithMembers210.query(
            project: project,
            :members.empty_or_nil => true,
          ).group_by(:status).count
          puts "Query: project, :members.empty_or_nil => true, group_by(:status).count"
          puts "Results: #{results_group.inspect}"

          assert results_group.key?("active"), "Should have active status"
          assert_equal 2, results_group["active"], "Should have 2 active empty teams"

          puts "✅ group_by with pointer array constraints works!"
        rescue => e
          puts "❌ Test failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(10).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 22: Lookup/Join - filter by related object's property (in_query)
  # e.g., find teams where team.project.status == "active"
  # ==========================================================================
  def test_lookup_filter_by_related_object_property
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      puts "\n=== Testing Lookup Filter by Related Object Property ==="

      active_project = nil
      inactive_project = nil
      members = []

      with_timeout(15, "creating test data for lookup tests") do
        # Create projects with different statuses
        active_project = ProjectTest210.new(name: "Active Project", status: "active")
        active_project.save
        puts "Created active project: #{active_project.id}"

        inactive_project = ProjectTest210.new(name: "Inactive Project", status: "inactive")
        inactive_project.save
        puts "Created inactive project: #{inactive_project.id}"

        # Create members
        2.times do |i|
          member = MemberTest210.new(name: "Member #{i + 1}", role: "developer")
          member.save
          members << member
        end

        sleep(0.3)

        # Create teams under different projects
        t1 = TeamWithMembers210.new(name: "team_active_with_members", project: active_project, status: "active", members: members)
        t1.save
        puts "t1 (active project, has members) id=#{t1.id}"

        t2 = TeamWithMembers210.new(name: "team_active_empty", project: active_project, status: "active", members: [])
        t2.save
        puts "t2 (active project, empty) id=#{t2.id}"

        t3 = TeamWithMembers210.new(name: "team_inactive_with_members", project: inactive_project, status: "active", members: members)
        t3.save
        puts "t3 (inactive project, has members) id=#{t3.id}"

        t4 = TeamWithMembers210.new(name: "team_inactive_empty", project: inactive_project, status: "inactive", members: [])
        t4.save
        puts "t4 (inactive project, empty) id=#{t4.id}"
      end

      with_timeout(20, "testing lookup filters") do
        begin
          # Test in_query: find teams where project.status == "active"
          puts "\n--- Test: in_query (project.status == 'active') ---"
          active_projects_query = ProjectTest210.where("status" => "active")

          # Debug: verify the subquery works
          active_projects = active_projects_query.all
          puts "Active projects found: #{active_projects.map(&:name).inspect}"

          query = TeamWithMembers210.query(:project.in_query => active_projects_query)
          puts "Query constraints: #{query.constraints.inspect}"
          puts "Compiled where: #{query.compile_where.to_json}"

          results = query.all
          names = results.map(&:name).sort
          puts "Query: :project.in_query => (status == 'active')"
          puts "Results: #{names.inspect}"

          assert_includes names, "team_active_with_members", "Should match team with active project"
          assert_includes names, "team_active_empty", "Should match team with active project (empty)"
          refute_includes names, "team_inactive_with_members", "Should NOT match team with inactive project"
          refute_includes names, "team_inactive_empty", "Should NOT match team with inactive project"

          count = TeamWithMembers210.query(:project.in_query => active_projects_query).count
          puts "Count: #{count}"
          assert_equal results.count, count

          puts "✅ in_query (lookup) works!"

          # Test in_query combined with array constraint
          puts "\n--- Test: in_query + empty_or_nil ---"

          # First verify that empty_or_nil alone works
          test_empty = TeamWithMembers210.query(:members.empty_or_nil => true).all
          puts "empty_or_nil alone: #{test_empty.map(&:name).inspect}"

          # Test just the lookup part (without empty_or_nil)
          test_lookup = TeamWithMembers210.query(:project.in_query => active_projects_query).all
          puts "in_query alone (REST): #{test_lookup.map(&:name).inspect}"

          # First, test if basic $lookup works at all
          puts "\n--- Testing raw $lookup ---"

          # Debug: see raw results without SDK transformation
          raw_results = TeamWithMembers210.query.aggregate([]).raw
          puts "Raw results debug (first doc):"
          if raw_results.first
            puts "  Keys: #{raw_results.first.keys.inspect}"
            puts "  project field: #{raw_results.first["project"].inspect}"
          end

          # Debug: Try various field access patterns using $addFields only
          extract_debug = [
            {
              "$addFields" => {
                "test_project" => "$project",
                "test_p_project" => "$_p_project",
                # Try with objectToArray to see all fields
                "test_fields" => { "$objectToArray" => "$$ROOT" },
              },
            },
          ]
          extract_results = TeamWithMembers210.query.aggregate(extract_debug).raw
          puts "\nExtract debug (first doc):"
          if extract_results.first
            r = extract_results.first
            puts "  test_project: #{r["test_project"].inspect}"
            puts "  test_p_project: #{r["test_p_project"].inspect}"
            # Show field names from objectToArray
            if r["test_fields"].is_a?(Array)
              puts "  Available fields: #{r["test_fields"].map { |f| f["k"] }.inspect}"
            end
          end

          # Also check what projects look like
          project_debug = [
            {
              "$project" => {
                "name" => 1,
                "status" => 1,
                "objectId" => 1,
                "_id" => 1,
              },
            },
          ]
          project_results = ProjectTest210.query.aggregate(project_debug).results
          puts "\nProject debug:"
          project_results.each do |r|
            puts "  #{r["name"]}: _id=#{r["_id"].inspect}, objectId=#{r["objectId"].inspect}, status=#{r["status"]}"
          end

          # Parse Server returns pointer as: {"__type"=>"Pointer", "className"=>"ProjectTest210", "objectId"=>"xxx"}
          # So we can access $project.objectId directly and join on objectId
          pointer_lookup = [
            {
              "$addFields" => {
                "projectId" => "$project.objectId",
              },
            },
            {
              "$lookup" => {
                "from" => "ProjectTest210",
                "localField" => "projectId",
                "foreignField" => "objectId",
                "as" => "projectData",
              },
            },
          ]
          pointer_results = TeamWithMembers210.query.aggregate(pointer_lookup).raw
          puts "\nPointer lookup (project.objectId -> objectId): #{pointer_results.length} results"
          pointer_results.each { |r| puts "  #{r["name"]}: projectId=#{r["projectId"]}, projectData=#{r["projectData"]&.length || 0} items" }

          # Also try direct join with pipeline syntax
          pipeline_lookup = [
            {
              "$lookup" => {
                "from" => "ProjectTest210",
                "let" => { "projId" => "$project.objectId" },
                "pipeline" => [
                  { "$match" => { "$expr" => { "$eq" => ["$objectId", "$$projId"] } } },
                ],
                "as" => "projectData",
              },
            },
          ]
          pipeline_results = TeamWithMembers210.query.aggregate(pipeline_lookup).raw
          puts "\nPipeline lookup (let projId = project.objectId): #{pipeline_results.length} results"
          pipeline_results.each { |r| puts "  #{r["name"]}: projectData=#{r["projectData"]&.length || 0} items" }

          # Test step by step - copy exact same pattern as extract_debug
          step0 = [
            {
              "$addFields" => {
                "test_project" => "$project",
                "test_p_project" => "$_p_project",
                "test_fields" => { "$objectToArray" => "$$ROOT" },
              },
            },
          ]
          step0_results = TeamWithMembers210.query.aggregate(step0).raw
          puts "\nStep 0 (same as extract_debug): #{step0_results.length} results"
          step0_results.each do |r|
            puts "  #{r["name"]}: test_p_project=#{r["test_p_project"].inspect}"
          end

          # ============================================================
          # TEST: Try same pipeline via MongoDB DIRECT to see if operators work
          # ============================================================
          puts "\n--- Testing via MongoDB Direct ---"
          begin
            require "mongo"
            require_relative "../../../lib/parse/mongodb"
            Parse::MongoDB.configure(uri: "mongodb://admin:password@localhost:27019/parse?authSource=admin", enabled: true)

            # Test $split via MongoDB direct using $literal to escape the dollar sign
            mongo_split_pipeline = [
              {
                "$addFields" => {
                  "_extracted_id" => {
                    "$arrayElemAt" => [{ "$split" => ["$_p_project", { "$literal" => "$" }] }, 1],
                  },
                },
              },
            ]
            mongo_split_results = Parse::MongoDB.aggregate("TeamWithMembers210", mongo_split_pipeline)
            puts "\nMongoDB Direct ($split with $literal): #{mongo_split_results.length} results"
            mongo_split_results.each do |r|
              puts "  #{r["name"]}: _extracted_id=#{r["_extracted_id"].inspect}"
            end

            # Test $lookup with $split via MongoDB direct
            mongo_lookup_pipeline = [
              {
                "$addFields" => {
                  "_extracted_id" => {
                    "$arrayElemAt" => [{ "$split" => ["$_p_project", { "$literal" => "$" }] }, 1],
                  },
                },
              },
              {
                "$lookup" => {
                  "from" => "ProjectTest210",
                  "localField" => "_extracted_id",
                  "foreignField" => "_id",
                  "as" => "_projectData",
                },
              },
            ]
            mongo_lookup_results = Parse::MongoDB.aggregate("TeamWithMembers210", mongo_lookup_pipeline)
            puts "\nMongoDB Direct ($split + $lookup): #{mongo_lookup_results.length} results"
            mongo_lookup_results.each do |r|
              puts "  #{r["name"]}: _extracted_id=#{r["_extracted_id"].inspect}, _projectData=#{r["_projectData"]&.length || 0} items"
            end

            # Test with where filter on lookup (in_query equivalent)
            mongo_inquery_pipeline = [
              {
                "$addFields" => {
                  "_extracted_id" => {
                    "$arrayElemAt" => [{ "$split" => ["$_p_project", { "$literal" => "$" }] }, 1],
                  },
                },
              },
              {
                "$lookup" => {
                  "from" => "ProjectTest210",
                  "let" => { "projId" => "$_extracted_id" },
                  "pipeline" => [
                    { "$match" => { "$expr" => { "$eq" => ["$_id", "$$projId"] } } },
                    { "$match" => { "status" => "active" } },
                  ],
                  "as" => "_projectData",
                },
              },
              {
                "$match" => { "_projectData" => { "$ne" => [] } },
              },
            ]
            mongo_inquery_results = Parse::MongoDB.aggregate("TeamWithMembers210", mongo_inquery_pipeline)
            puts "\nMongoDB Direct (in_query equivalent): #{mongo_inquery_results.length} results"
            mongo_inquery_results.each do |r|
              puts "  #{r["name"]}"
            end

            # Don't reset MongoDB - keep it enabled for auto-detection in combo test
            puts "MongoDB direct tests passed - keeping MongoDB enabled for auto-detection"
          rescue LoadError => e
            puts "MongoDB gem not available, skipping direct tests: #{e.message}"
          rescue => e
            puts "MongoDB direct test error: #{e.class}: #{e.message}"
            Parse::MongoDB.reset! if defined?(Parse::MongoDB)
          end
          puts "--- End MongoDB Direct Testing ---\n"

          # Try $project with $substr (exactly like Parse Server test)
          # ProjectTest210$ is 16 characters (15 for class name + 1 for $)
          step1 = [
            {
              "$project" => {
                "name" => 1,
                "members" => 1,
                "_extracted_id" => { "$substr" => ["$_p_project", 16, -1] },
              },
            },
          ]
          step1_results = TeamWithMembers210.query.aggregate(step1).raw
          puts "\nStep 1 via Parse Server ($project + $substr): #{step1_results.length} results"
          step1_results.each do |r|
            puts "  #{r["name"]}: _extracted_id=#{r["_extracted_id"].inspect}"
          end

          # Now add the $lookup via Parse Server
          step2 = [
            {
              "$addFields" => {
                "_extracted_id" => {
                  "$arrayElemAt" => [{ "$split" => ["$_p_project", "$"] }, 1],
                },
              },
            },
            {
              "$lookup" => {
                "from" => "ProjectTest210",
                "localField" => "_extracted_id",
                "foreignField" => "_id",
                "as" => "_projectData",
              },
            },
          ]
          step2_results = TeamWithMembers210.query.aggregate(step2).raw
          puts "\nStep 2 via Parse Server ($split + $lookup): #{step2_results.length} results"
          step2_results.each do |r|
            puts "  #{r["name"]}: _extracted_id=#{r["_extracted_id"].inspect}, _projectData=#{r["_projectData"]&.length || 0} items"
          end

          # Test in_query through aggregation mode
          puts "\n--- Testing aggregate_from_query with MongoDB direct ---"
          mongodb_enabled = defined?(Parse::MongoDB) && Parse::MongoDB.enabled?
          puts "Parse::MongoDB.enabled? = #{mongodb_enabled}"
          in_query_agg = TeamWithMembers210.query(:project.in_query => active_projects_query)
          puts "has_subquery_constraints? = #{in_query_agg.send(:has_subquery_constraints?, in_query_agg.compile_where)}"
          agg = in_query_agg.aggregate_from_query([], verbose: true)
          puts "Aggregation mongo_direct: #{agg.instance_variable_get(:@mongo_direct)}"
          agg_results = agg.results
          puts "in_query via aggregate_from_query: #{agg_results.map { |r| r.respond_to?(:name) ? r.name : r["name"] }.inspect}"

          query_combo = TeamWithMembers210.query(
            :project.in_query => active_projects_query,
            :members.empty_or_nil => true,
          )
          puts "Compiled where: #{query_combo.compile_where.to_json}"
          puts "Pipeline: #{JSON.pretty_generate(query_combo.send(:build_aggregation_pipeline))}"
          results_combo = query_combo.all
          names_combo = results_combo.map(&:name).sort
          puts "Query: :project.in_query => (active), :members.empty_or_nil => true"
          puts "Results: #{names_combo.inspect}"

          assert_includes names_combo, "team_active_empty", "Should match active project + empty members"
          refute_includes names_combo, "team_active_with_members", "Should NOT match team with members"
          refute_includes names_combo, "team_inactive_empty", "Should NOT match inactive project"

          count_combo = TeamWithMembers210.query(
            :project.in_query => active_projects_query,
            :members.empty_or_nil => true,
          ).count
          puts "Count: #{count_combo}"
          assert_equal results_combo.count, count_combo

          puts "✅ in_query + empty_or_nil combo works!"

          # Test not_in_query: find teams where project.status != "active"
          puts "\n--- Test: not_in_query (project.status != 'active') ---"
          results_not = TeamWithMembers210.query(
            :project.not_in_query => active_projects_query,
          ).all
          names_not = results_not.map(&:name).sort
          puts "Query: :project.not_in_query => (status == 'active')"
          puts "Results: #{names_not.inspect}"

          assert_includes names_not, "team_inactive_with_members", "Should match team with inactive project"
          assert_includes names_not, "team_inactive_empty", "Should match team with inactive project"
          refute_includes names_not, "team_active_with_members", "Should NOT match team with active project"

          puts "✅ not_in_query (lookup) works!"

          # Test in_query with not_empty array constraint
          puts "\n--- Test: in_query + not_empty ---"
          results_not_empty = TeamWithMembers210.query(
            :project.in_query => active_projects_query,
            :members.not_empty => true,
          ).all
          names_not_empty = results_not_empty.map(&:name).sort
          puts "Query: :project.in_query => (active), :members.not_empty => true"
          puts "Results: #{names_not_empty.inspect}"

          assert_includes names_not_empty, "team_active_with_members", "Should match active project + has members"
          refute_includes names_not_empty, "team_active_empty", "Should NOT match empty team"
          refute_includes names_not_empty, "team_inactive_with_members", "Should NOT match inactive project"

          puts "✅ in_query + not_empty works!"

          # Test group_by with lookup + array constraint
          puts "\n--- Test: group_by with in_query + array constraint ---"
          results_group = TeamWithMembers210.query(
            :project.in_query => active_projects_query,
          ).group_by(:status).count
          puts "Query: :project.in_query => (active), group_by(:status).count"
          puts "Results: #{results_group.inspect}"

          assert results_group.key?("active"), "Should have active status"
          assert_equal 2, results_group["active"], "Should have 2 active teams under active project"

          puts "✅ group_by with lookup works!"
        rescue => e
          puts "❌ Test failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(10).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 23: Lookup with array of pointers - filter by member's property
  # e.g., find teams that have at least one member with role == "admin"
  # ==========================================================================
  def test_lookup_filter_by_array_member_property
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      puts "\n=== Testing Lookup Filter by Array Member Property ==="

      project = nil
      admin = nil
      developers = []

      with_timeout(15, "creating test data for member lookup tests") do
        # Create project
        project = ProjectTest210.new(name: "Member Lookup Project")
        project.save
        puts "Created project: #{project.id}"

        # Create members with different roles
        admin = MemberTest210.new(name: "Admin User", role: "admin")
        admin.save
        puts "Created admin: #{admin.id}"

        2.times do |i|
          dev = MemberTest210.new(name: "Developer #{i + 1}", role: "developer")
          dev.save
          developers << dev
          puts "Created developer: #{dev.id}"
        end

        sleep(0.3)

        # Teams with different member compositions
        t1 = TeamWithMembers210.new(name: "team_with_admin", project: project, status: "active", members: [admin, developers[0]])
        t1.save
        puts "t1 (has admin) id=#{t1.id}"

        t2 = TeamWithMembers210.new(name: "team_devs_only", project: project, status: "active", members: developers)
        t2.save
        puts "t2 (devs only) id=#{t2.id}"

        t3 = TeamWithMembers210.new(name: "team_admin_only", project: project, status: "inactive", members: [admin])
        t3.save
        puts "t3 (admin only) id=#{t3.id}"

        t4 = TeamWithMembers210.new(name: "team_empty", project: project, status: "active", members: [])
        t4.save
        puts "t4 (empty) id=#{t4.id}"
      end

      with_timeout(20, "testing lookup filters by member property") do
        begin
          # Find teams that contain at least one admin using contains_all with query result
          # First, find all admins
          puts "\n--- Test: contains_all with admin member ---"
          results = TeamWithMembers210.query(
            project: project,
            :members.contains_all => [admin],
          ).all
          names = results.map(&:name).sort
          puts "Query: project, :members.contains_all => [admin]"
          puts "Results: #{names.inspect}"

          assert_includes names, "team_with_admin", "Should match team with admin"
          assert_includes names, "team_admin_only", "Should match team with only admin"
          refute_includes names, "team_devs_only", "Should NOT match team without admin"
          refute_includes names, "team_empty", "Should NOT match empty team"

          count = TeamWithMembers210.query(project: project, :members.contains_all => [admin]).count
          puts "Count: #{count}"
          assert_equal results.count, count

          puts "✅ contains_all lookup for specific member works!"

          # Find teams with either admin or first developer
          puts "\n--- Test: any with specific members ---"
          results_any = TeamWithMembers210.query(
            project: project,
            :members.any => [admin, developers[0]],
          ).all
          names_any = results_any.map(&:name).sort
          puts "Query: project, :members.any => [admin, dev1]"
          puts "Results: #{names_any.inspect}"

          assert_includes names_any, "team_with_admin", "Should match team with admin"
          assert_includes names_any, "team_admin_only", "Should match team with admin"
          assert_includes names_any, "team_devs_only", "Should match team with dev1"
          refute_includes names_any, "team_empty", "Should NOT match empty team"

          puts "✅ any lookup for specific members works!"

          # Combined: has admin AND project filter AND status
          puts "\n--- Test: contains_all + project + status ---"
          results_combo = TeamWithMembers210.query(
            project: project,
            status: "active",
            :members.contains_all => [admin],
          ).all
          names_combo = results_combo.map(&:name).sort
          puts "Query: project, status: 'active', :members.contains_all => [admin]"
          puts "Results: #{names_combo.inspect}"

          assert_includes names_combo, "team_with_admin", "Should match active team with admin"
          refute_includes names_combo, "team_admin_only", "Should NOT match inactive team"

          count_combo = TeamWithMembers210.query(
            project: project,
            status: "active",
            :members.contains_all => [admin],
          ).count
          puts "Count: #{count_combo}"
          assert_equal results_combo.count, count_combo

          puts "✅ contains_all + project + status combo works!"
        rescue => e
          puts "❌ Test failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(10).join("\n")
          raise
        end
      end
    end
  end
end
