# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper_integration"

# End-to-end verification that Parse::LookupRewriter produces a pipeline
# that, when executed against the real MongoDB backing Parse Server, returns
# the correctly joined documents.
#
# Strategy:
# 1. Create a parent (LRIntCompany) with parse_reference and a child
#    (LRIntEmployee) that belongs_to :company.
# 2. Insert one company + two employees.
# 3. Generate the LLM-style pipeline that any standard MongoDB-trained model
#    would produce: from "LRIntCompany", localField "company",
#    foreignField "_id".
# 4. Confirm the unmodified pipeline returns no joined docs (proves the
#    rewrite is necessary).
# 5. Pass it through Parse::LookupRewriter.rewrite and run via
#    Parse::MongoDB.aggregate -- joined documents must come back.

class LRIntCompany < Parse::Object
  parse_class "LRIntCompany"
  property :name, :string
  parse_reference
end

class LRIntEmployee < Parse::Object
  parse_class "LRIntEmployee"
  property :name, :string
  belongs_to :company, class_name: "LRIntCompany"
  parse_reference
end

# Foreign without parse_reference -- exercises the $arrayElemAt + $split
# fallback path on a real MongoDB.
class LRIntDepartment < Parse::Object
  parse_class "LRIntDepartment"
  property :name, :string
end

class LRIntContractor < Parse::Object
  parse_class "LRIntContractor"
  property :name, :string
  belongs_to :department, class_name: "LRIntDepartment"
end

class LookupRewriterIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  MONGODB_URI = (ENV["PARSE_TEST_MONGO_URI"] || "mongodb://admin:password@localhost:29017/parse_stack_next_it?authSource=admin")

  def setup_mongodb_direct
    require "mongo"
    require "parse/mongodb"
    Parse::MongoDB.configure(uri: MONGODB_URI, enabled: true)
    true
  rescue LoadError => e
    puts "Skipping rewriter integration tests - mongo gem not installed: #{e.message}"
    false
  rescue => e
    puts "Skipping rewriter integration tests - configuration error: #{e.class}: #{e.message}"
    false
  end

  def teardown_mongodb_direct
    Parse::MongoDB.reset! if defined?(Parse::MongoDB)
  end

  def test_forward_join_rewrites_to_executable_lookup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      begin
        company = LRIntCompany.new(name: "Acme")
        assert company.save, "company must persist"
        assert company.parse_reference.present?, "after_create must populate parseReference"

        emp_a = LRIntEmployee.new(name: "Alice", company: company)
        emp_b = LRIntEmployee.new(name: "Bob", company: company)
        assert emp_a.save && emp_b.save
        sleep 0.2

        llm_style = [
          { "$match" => { "name" => { "$in" => ["Alice", "Bob"] } } },
          { "$lookup" => {
            "from" => "LRIntCompany",
            "localField" => "company",
            "foreignField" => "_id",
            "as" => "company_doc",
          } },
        ]

        # Sanity: pass `rewrite_lookups: false` so the auto-wiring stays out
        # of the way. The un-rewritten LLM-style pipeline must miss because
        # localField "company" doesn't exist (the actual column is
        # _p_company). This proves the rewrite is what makes the join work.
        raw_unrewritten = Parse::MongoDB.aggregate("LRIntEmployee", llm_style, rewrite_lookups: false, master: true)
        assert raw_unrewritten.all? { |doc| Array(doc["company_doc"]).empty? },
               "un-rewritten lookup should produce no joined docs (proves rewrite is needed). " \
               "Got: #{raw_unrewritten.inspect}"

        rewritten = Parse::LookupRewriter.rewrite(llm_style, local_class: LRIntEmployee)
        lookup_stage = rewritten[1]["$lookup"]
        assert_equal "_p_company", lookup_stage["localField"]
        assert_equal "parseReference", lookup_stage["foreignField"]

        # Now go through the auto-wired path -- no explicit rewrite call,
        # the gem rewrites for us when it sees parse_reference is available.
        results = Parse::MongoDB.aggregate("LRIntEmployee", llm_style, master: true)
        assert_equal 2, results.size, "both employees should come back"
        results.each do |doc|
          joined = doc["company_doc"]
          assert joined.is_a?(Array), "lookup output must be an array: #{doc.inspect}"
          assert_equal 1, joined.size, "exactly one company should match"
          assert_equal "Acme", joined.first["name"]
        end
      ensure
        teardown_mongodb_direct
      end
    end
  end

  def test_query_aggregate_auto_rewrites_when_parse_reference_available
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      begin
        company = LRIntCompany.new(name: "Initech")
        assert company.save
        emp = LRIntEmployee.new(name: "Gilfoyle", company: company)
        assert emp.save
        sleep 0.2

        llm_pipeline = [
          { "$lookup" => {
            "from" => "LRIntCompany",
            "localField" => "company",
            "foreignField" => "_id",
            "as" => "company_doc",
          } },
        ]

        # Through Parse::Query#aggregate with mongo_direct: true. The query's
        # @table is "LRIntEmployee" so auto_rewrite resolves the local class
        # and translates the lookup.
        agg = LRIntEmployee.query.aggregate(llm_pipeline, mongo_direct: true)
        results = agg.raw
        assert results.size >= 1, "auto-rewrite should make the join work via Query#aggregate"
        joined = results.first["company_doc"]
        assert joined.is_a?(Array) && !joined.empty?,
               "joined company_doc must be populated: #{results.first.inspect}"
      ensure
        teardown_mongodb_direct
      end
    end
  end

  def test_forward_join_fallback_when_foreign_lacks_parse_reference
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      begin
        dept = LRIntDepartment.new(name: "Engineering")
        assert dept.save
        c1 = LRIntContractor.new(name: "Eve", department: dept)
        c2 = LRIntContractor.new(name: "Frank", department: dept)
        assert c1.save && c2.save
        sleep 0.2

        llm_style = [
          { "$match" => { "name" => { "$in" => %w[Eve Frank] } } },
          { "$lookup" => {
            "from" => "LRIntDepartment",
            "localField" => "department",
            "foreignField" => "_id",
            "as" => "department_doc",
          } },
        ]

        # Sanity: un-rewritten LLM pipeline must miss. localField "department"
        # doesn't exist (the column is _p_department), so the join finds nothing.
        raw_unrewritten = Parse::MongoDB.aggregate("LRIntContractor", llm_style, master: true)
        assert raw_unrewritten.all? { |doc| Array(doc["department_doc"]).empty? },
               "un-rewritten lookup must miss when foreign has no parseReference. " \
               "Got: #{raw_unrewritten.inspect}"

        rewritten = Parse::LookupRewriter.rewrite(llm_style, local_class: LRIntContractor)
        lookup_stage = rewritten[1]["$lookup"]
        refute lookup_stage.key?("localField"),
               "fallback form must drop localField; got #{lookup_stage.inspect}"
        refute lookup_stage.key?("foreignField"),
               "fallback form must drop foreignField"
        assert lookup_stage["let"].is_a?(Hash)
        assert lookup_stage["pipeline"].is_a?(Array)

        results = Parse::MongoDB.aggregate("LRIntContractor", rewritten, master: true)
        assert_equal 2, results.size
        results.each do |doc|
          joined = doc["department_doc"]
          assert_equal 1, joined.size, "fallback $split must still match exactly one dept"
          assert_equal "Engineering", joined.first["name"]
        end
      ensure
        teardown_mongodb_direct
      end
    end
  end

  def test_reverse_join_rewrites_to_executable_lookup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      begin
        company = LRIntCompany.new(name: "Globex")
        assert company.save
        emp_a = LRIntEmployee.new(name: "Carol", company: company)
        emp_b = LRIntEmployee.new(name: "Dave", company: company)
        assert emp_a.save && emp_b.save
        sleep 0.2

        # Inverse direction: starting from companies, attach each company's
        # employees via $lookup.
        llm_style = [
          { "$match" => { "name" => "Globex" } },
          { "$lookup" => {
            "from" => "LRIntEmployee",
            "localField" => "_id",
            "foreignField" => "company",
            "as" => "employees",
          } },
        ]

        # Naive form: foreignField "company" doesn't exist; column is
        # _p_company. Pass rewrite_lookups: false so the auto-wiring stays
        # out of the way for the demonstration.
        raw_unrewritten = Parse::MongoDB.aggregate("LRIntCompany", llm_style, rewrite_lookups: false, master: true)
        assert raw_unrewritten.all? { |d| Array(d["employees"]).empty? },
               "un-rewritten reverse lookup should produce no joined docs"

        rewritten = Parse::LookupRewriter.rewrite(llm_style, local_class: LRIntCompany)
        lookup_stage = rewritten[1]["$lookup"]
        assert_equal "parseReference", lookup_stage["localField"]
        assert_equal "_p_company", lookup_stage["foreignField"]

        # Auto-wired path -- no explicit rewrite, gem handles it.
        results = Parse::MongoDB.aggregate("LRIntCompany", llm_style, master: true)
        assert_equal 1, results.size
        names = results.first["employees"].map { |e| e["name"] }.sort
        assert_equal %w[Carol Dave], names
      ensure
        teardown_mongodb_direct
      end
    end
  end
end
