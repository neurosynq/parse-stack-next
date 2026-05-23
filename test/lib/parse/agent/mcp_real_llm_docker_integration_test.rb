# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper_integration"
require "parse/agent"
require "parse/agent/mcp_dispatcher"
require "net/http"
require "json"
require "uri"
require "securerandom"

# ============================================================================
# Real-LLM × real-Parse-Server integration test for the MCP layer.
#
# Unlike `mcp_real_llm_smoke_test.rb` (which stubs Parse::Agent#execute), this
# test exercises the FULL stack end-to-end:
#
#   1. Boot fixtures against the Dockerized Parse Server (scripts/docker/
#      docker-compose.test.yml). Real records are seeded into a real class.
#   2. Build a real Parse::Agent that hits the running Parse Server.
#   3. Translate the agent's MCP tools/list to OpenAI/Anthropic function-
#      calling schema and hand them to a real LLM.
#   4. Ask the LLM a question that requires calling tools to answer.
#   5. Dispatch every tool call through MCPDispatcher -> real Agent ->
#      real Parse Server -> real MongoDB.
#   6. Verify the LLM's final answer reflects the actual seeded data.
#
# Skipped unless BOTH:
#   - PARSE_TEST_USE_DOCKER=true   (the Docker compose stack is up)
#   - LLM_PROVIDER + LLM_API_KEY   (real LLM is configured)
#
# Catches integration regressions across THREE seams at once:
#   - MCP wire protocol vs. what the LLM tool decoder expects.
#   - Agent.execute -> Parse Server REST round-trip (auth, schemas, queries).
#   - Tool-result serialization -> what the LLM sees -> its final synthesis.
#
# A single failing run of this test means the integration is broken; a
# passing run means an external MCP client (Claude Desktop, Cursor, LM
# Studio) will work against this server at protocol level.
# ============================================================================
class MCPLLMxParseIntegrationTest < Minitest::Test
  # The integration mixin handles Parse.setup against the Docker harness,
  # injects per-test setup/teardown, and provides #reset_database! etc.
  # It also gates on PARSE_TEST_USE_DOCKER inside its setup hook.
  include ParseStackIntegrationTest

  # --------------------------------------------------------------------------
  # Fixture class definitions
  # --------------------------------------------------------------------------
  #
  # Six-class school-domain graph:
  #   MCPSchoolSubject <- MCPSchoolTeacher <- MCPSchoolStudent
  #   MCPSchoolSubject <- MCPSchoolAssignment
  #   MCPSchoolSubject <- MCPSchoolExam
  #   MCPSchoolStudent + MCPSchoolSubject <- MCPSchoolAttendance
  #
  # The LLM cannot answer the test prompts without traversing this graph
  # via real pointer queries against the live Parse Server.

  class MCPSchoolSubject < Parse::Object
    parse_class "MCPSchoolSubject"
    property :name, :string         # e.g. "Algebra II"
    property :department, :string   # e.g. "Mathematics"
    property :level, :string        # "intro" | "advanced"
  end

  class MCPSchoolTeacher < Parse::Object
    parse_class "MCPSchoolTeacher"
    property :name, :string
    property :rating, :float
    property :years_experience, :integer
    belongs_to :subject, as: :pointer, class_name: "MCPSchoolSubject"
  end

  class MCPSchoolStudent < Parse::Object
    parse_class "MCPSchoolStudent"
    property :name, :string
    property :grade, :integer
    belongs_to :teacher, as: :pointer, class_name: "MCPSchoolTeacher"
  end

  class MCPSchoolAssignment < Parse::Object
    parse_class "MCPSchoolAssignment"
    property :title, :string
    property :total_points, :integer
    property :due_date, :date
    belongs_to :subject, as: :pointer, class_name: "MCPSchoolSubject"
  end

  class MCPSchoolExam < Parse::Object
    parse_class "MCPSchoolExam"
    property :title, :string
    property :max_score, :integer
    property :exam_date, :date
    belongs_to :subject, as: :pointer, class_name: "MCPSchoolSubject"
  end

  class MCPSchoolAttendance < Parse::Object
    parse_class "MCPSchoolAttendance"
    property :status, :string         # "present" | "absent" | "late"
    property :attendance_date, :date
    belongs_to :student, as: :pointer, class_name: "MCPSchoolStudent"
    belongs_to :subject, as: :pointer, class_name: "MCPSchoolSubject"
  end

  # --------------------------------------------------------------------------
  # Fixture data constants
  # --------------------------------------------------------------------------

  SUBJECT_FIXTURES = [
    { name: "Algebra II",       department: "Mathematics", level: "advanced" },
    { name: "World Literature", department: "English",     level: "intro"    },
    { name: "Biology",          department: "Sciences",    level: "advanced" },
  ].freeze

  # Each teacher maps 1:1 to one subject, keeping assertion language clean.
  TEACHER_TO_SUBJECT = {
    "Ms. Vasquez" => "Algebra II",
    "Mr. Okafor"  => "World Literature",
    "Mrs. Davies" => "Biology",
  }.freeze

  TEACHER_FIXTURES = [
    { name: "Ms. Vasquez", rating: 4.9, years_experience: 12 },
    { name: "Mr. Okafor",  rating: 4.2, years_experience:  6 },
    { name: "Mrs. Davies", rating: 4.6, years_experience:  9 },
  ].freeze

  # Distribution: Vasquez=5, Okafor=3, Davies=4. Total: 12 students.
  STUDENT_DISTRIBUTION = {
    "Ms. Vasquez" => %w[Ada Bao Cheng Diego Esi],
    "Mr. Okafor"  => %w[Fatima Goro Hana],
    "Mrs. Davies" => %w[Idris Junia Kiri Lukas],
  }.freeze

  # Attendance ground truths:
  #   Each student has 4 records: 3 "present" + 1 non-present.
  #   Global student order: Ada(0), Bao(1), Cheng(2), Diego(3), Esi(4),
  #     Fatima(5), Goro(6), Hana(7), Idris(8), Junia(9), Kiri(10), Lukas(11)
  #   Even-index students get "absent" as 4th record.
  #   Odd-index students get "late" as 4th record.
  #   => 6 "absent" rows, 6 "late" rows, 36 "present" rows. Total: 48 rows.

  # NOTE: do NOT override `def setup` / `def teardown` here.
  # `ParseStackIntegrationTest.included(base)` injects setup via
  # `base.define_method :setup` (see test/test_helper_integration.rb); a
  # subclass `def setup` would replace that injection, and the Parse client
  # would never be configured. Per-test gating + fixture seeding happen
  # inside each test method via the `with_school_fixtures` block helper.

  # The ordered list of MCPSchool* class names that must exist as schemas.
  # Drop order is reverse-dependency (deepest dependents first) to avoid
  # Parse Server "class still has objects" rejections on schema DELETE.
  MCP_SCHOOL_CLASSES = %w[
    MCPSchoolAttendance
    MCPSchoolExam
    MCPSchoolAssignment
    MCPSchoolStudent
    MCPSchoolTeacher
    MCPSchoolSubject
  ].freeze

  # --------------------------------------------------------------------------
  # Block helper: seed all 6 fixture classes in dependency order, yield to
  # the test block, tear down in reverse order in `ensure`.
  #
  # We also drop any stale MCPSchool* class schemas at the start. Parse Server
  # retains column-type information across test runs; a column that was once
  # stored as String cannot be silently coerced to Pointer. Dropping the empty
  # schema before re-seeding ensures the correct column types are inferred on
  # first insert.
  #
  # Dependency order:
  #   subjects -> teachers (needs subject ptr) -> students (needs teacher ptr)
  #   -> assignments (needs subject ptr) -> exams (needs subject ptr)
  #   -> attendance (needs student + subject ptrs)
  #
  # Yield args: subjects, teachers, students, assignments, exams, attendance
  # --------------------------------------------------------------------------
  def with_school_fixtures
    # Drop stale schemas so column types are re-inferred on first insert.
    drop_mcp_school_schemas!

    subjects = SUBJECT_FIXTURES.map do |attrs|
      s = MCPSchoolSubject.new(attrs)
      assert s.save, "subject save failed for #{attrs[:name]}: #{s.errors.full_messages.join(", ")}"
      s
    end
    subjects_by_name = subjects.each_with_object({}) { |s, h| h[s.name] = s }

    teachers = TEACHER_FIXTURES.map do |attrs|
      subject_name = TEACHER_TO_SUBJECT.fetch(attrs[:name])
      t = MCPSchoolTeacher.new(attrs.merge(subject: subjects_by_name.fetch(subject_name)))
      assert t.save, "teacher save failed for #{attrs[:name]}: #{t.errors.full_messages.join(", ")}"
      t
    end
    teachers_by_name = teachers.each_with_object({}) { |t, h| h[t.name] = t }

    students = STUDENT_DISTRIBUTION.flat_map do |teacher_name, student_names|
      teacher = teachers_by_name.fetch(teacher_name)
      student_names.each_with_index.map do |name, i|
        s = MCPSchoolStudent.new(name: name, grade: 10 + (i % 3), teacher: teacher)
        assert s.save, "student save failed for #{name}: #{s.errors.full_messages.join(", ")}"
        s
      end
    end

    # Assignments: 2 per subject. Title: "<Subject> Homework <n>". Points: 50 or 100.
    base_date = Date.today
    assignments = subjects.flat_map.with_index do |subject, si|
      [1, 2].map do |n|
        a = MCPSchoolAssignment.new(
          title:        "#{subject.name} Homework #{n}",
          total_points: n.odd? ? 50 : 100,
          due_date:     base_date + ((si * 2 + n) * 7),
          subject:      subject
        )
        assert a.save, "assignment save failed for #{a.title}: #{a.errors.full_messages.join(", ")}"
        a
      end
    end

    # Exams: 1 per subject. Title: "<Subject> Midterm". Max score: 100.
    exam_date = base_date + 14
    exams = subjects.map do |subject|
      e = MCPSchoolExam.new(
        title:     "#{subject.name} Midterm",
        max_score: 100,
        exam_date: exam_date,
        subject:   subject
      )
      assert e.save, "exam save failed for #{e.title}: #{e.errors.full_messages.join(", ")}"
      e
    end

    # Attendance: 4 records per student for that student's teacher's subject.
    # Build a lookup: teacher id -> subject object (already in memory).
    teacher_subject = teachers.each_with_object({}) do |t, h|
      subject_name = TEACHER_TO_SUBJECT.fetch(t.name)
      h[t.id] = subjects_by_name.fetch(subject_name)
    end

    global_idx = 0
    attendance = students.flat_map do |student|
      subject = teacher_subject.fetch(student.teacher.id)
      non_present = global_idx.even? ? "absent" : "late"
      global_idx += 1

      (1..4).map do |day|
        status = day <= 3 ? "present" : non_present
        rec = MCPSchoolAttendance.new(
          status:          status,
          attendance_date: base_date - (4 - day),
          student:         student,
          subject:         subject
        )
        assert rec.save, "attendance save failed: #{rec.errors.full_messages.join(", ")}"
        rec
      end
    end

    yield subjects, teachers, students, assignments, exams, attendance
  ensure
    (attendance  || []).each { |r| r.destroy rescue nil }
    (exams       || []).each { |e| e.destroy rescue nil }
    (assignments || []).each { |a| a.destroy rescue nil }
    (students    || []).each { |s| s.destroy rescue nil }
    (teachers    || []).each { |t| t.destroy rescue nil }
    (subjects    || []).each { |s| s.destroy rescue nil }
  end

  # --------------------------------------------------------------------------
  # Test 1: Direct lookup — teacher -> subject via include.
  #
  # The LLM must call query_class on MCPSchoolTeacher with name == "Ms. Vasquez"
  # and include: ["subject"] to resolve the subject name inline (or follow up
  # with get_object). Ground truth: Ms. Vasquez teaches Algebra II.
  # --------------------------------------------------------------------------
  def test_direct_teacher_subject_lookup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Set LLM_PROVIDER (lmstudio | openai | anthropic) to run" unless ENV["LLM_PROVIDER"]
    skip "openai/anthropic require LLM_API_KEY" if %w[openai anthropic].include?(ENV["LLM_PROVIDER"]) && ENV["LLM_API_KEY"].to_s.empty?
    configure_llm_provider!

    with_school_fixtures do |subjects, teachers, students, assignments, exams, attendance|
      agent = Parse::Agent.new(permissions: :readonly)
      openai_tools = fetch_openai_tools(agent)

      prompt = build_school_prompt(
        "What subject does Ms. Vasquez teach? Answer in ONE sentence: \"Ms. Vasquez teaches <subject name>.\"",
        hints: [
          "Call query_class with class_name: 'MCPSchoolTeacher', where: {\"name\": \"Ms. Vasquez\"}, include: [\"subject\"].",
          "The subject name is in the 'name' field of the included MCPSchoolSubject object.",
        ]
      )

      transcript = llm_round_trip(prompt: prompt, tools: openai_tools, agent: agent, max_iterations: 8)
      flat       = transcript_text(transcript)
      tool_calls = transcript_tool_names(transcript)

      refute_empty tool_calls, "model must invoke at least one MCP tool; got none"
      assert (tool_calls & %w[query_class get_object get_objects]).any?,
             "model should invoke a data-fetching tool; got #{tool_calls.inspect}"
      assert_match(/Algebra/i, flat,
                   "model must identify 'Algebra II' as Vasquez's subject; got: #{flat[0, 600]}")
    end
  end

  # --------------------------------------------------------------------------
  # Test 2: Pointer chain — student name -> teacher + subject.
  #
  # The LLM must find the student named "Cheng", follow the teacher pointer
  # to Ms. Vasquez, then resolve Vasquez's subject pointer to "Algebra II".
  # Ground truth: Cheng is taught by Ms. Vasquez who teaches Algebra II.
  # --------------------------------------------------------------------------
  def test_pointer_chain_student_to_teacher_to_subject
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Set LLM_PROVIDER (lmstudio | openai | anthropic) to run" unless ENV["LLM_PROVIDER"]
    skip "openai/anthropic require LLM_API_KEY" if %w[openai anthropic].include?(ENV["LLM_PROVIDER"]) && ENV["LLM_API_KEY"].to_s.empty?
    configure_llm_provider!

    with_school_fixtures do |subjects, teachers, students, assignments, exams, attendance|
      agent = Parse::Agent.new(permissions: :readonly)
      openai_tools = fetch_openai_tools(agent)

      prompt = build_school_prompt(
        "Who teaches the student named Cheng, and what subject do they teach? " \
        "Answer in ONE sentence: \"Cheng is taught by <teacher name>, who teaches <subject name>.\"",
        hints: [
          "Step 1: call query_class with class_name: 'MCPSchoolStudent', where: {\"name\": \"Cheng\"}, include: [\"teacher\"] to get the teacher.",
          "Step 2: from the teacher record you got, call get_object on MCPSchoolTeacher with that teacher's objectId and include: [\"subject\"] to resolve the subject.",
          "The subject name is in the 'name' field of MCPSchoolSubject.",
        ]
      )

      transcript = llm_round_trip(prompt: prompt, tools: openai_tools, agent: agent, max_iterations: 8)
      flat       = transcript_text(transcript)
      tool_calls = transcript_tool_names(transcript)

      refute_empty tool_calls, "model must invoke at least one MCP tool; got none"
      assert (tool_calls & %w[query_class get_object get_objects]).any?,
             "model should invoke a data-fetching tool; got #{tool_calls.inspect}"
      assert_match(/Vasquez/i, flat,
                   "model must identify Ms. Vasquez as Cheng's teacher; got: #{flat[0, 600]}")
      assert_match(/Algebra/i, flat,
                   "model must identify Algebra II as the subject; got: #{flat[0, 600]}")
    end
  end

  # --------------------------------------------------------------------------
  # Test 3: Reverse count — how many students study Algebra II?
  #
  # The LLM must find Ms. Vasquez (who teaches Algebra II), then count
  # MCPSchoolStudent records whose teacher pointer equals Vasquez's objectId.
  # Ground truth: 5 students (Ada, Bao, Cheng, Diego, Esi).
  # --------------------------------------------------------------------------
  def test_reverse_count_students_in_subject
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Set LLM_PROVIDER (lmstudio | openai | anthropic) to run" unless ENV["LLM_PROVIDER"]
    skip "openai/anthropic require LLM_API_KEY" if %w[openai anthropic].include?(ENV["LLM_PROVIDER"]) && ENV["LLM_API_KEY"].to_s.empty?
    configure_llm_provider!

    with_school_fixtures do |subjects, teachers, students, assignments, exams, attendance|
      agent = Parse::Agent.new(permissions: :readonly)
      openai_tools = fetch_openai_tools(agent)

      prompt = build_school_prompt(
        "How many students study Algebra II? " \
        "Answer in ONE sentence: \"There are <N> students studying Algebra II.\"",
        hints: [
          "Step 1: call query_class with EXACTLY these arguments: " \
          "{\"class_name\": \"MCPSchoolTeacher\", \"where\": {\"name\": \"Ms. Vasquez\"}, \"limit\": 1}. " \
          "Note the 'name' field value 'Ms. Vasquez' with the Ms. prefix. Vasquez teaches Algebra II.",
          "Step 2: from the result, copy the 'objectId' value (e.g. 'abc123'). " \
          "Then call count_objects with EXACTLY this shape: " \
          "{\"class_name\": \"MCPSchoolStudent\", \"where\": {\"teacher\": {\"__type\": \"Pointer\", \"className\": \"MCPSchoolTeacher\", \"objectId\": \"<paste_vasquez_objectId_here>\"}}}. " \
          "The 'where' field is REQUIRED — omitting it returns 12 (all students), not 5.",
        ]
      )

      transcript = llm_round_trip(prompt: prompt, tools: openai_tools, agent: agent, max_iterations: 8)
      flat       = transcript_text(transcript)
      tool_calls = transcript_tool_names(transcript)

      refute_empty tool_calls, "model must invoke at least one MCP tool; got none"
      assert (tool_calls & %w[query_class count_objects get_object]).any?,
             "model should invoke a data-fetching tool; got #{tool_calls.inspect}"
      assert_match(/\b5\b|five/i, flat,
                   "model must report 5 students for Algebra II; got: #{flat[0, 600]}")
    end
  end

  # --------------------------------------------------------------------------
  # Test 4: Filtered count — how many "absent" attendance records exist?
  #
  # The LLM just needs to call count_objects on MCPSchoolAttendance with
  # where: {"status": "absent"}. Ground truth: 6 absent rows.
  # --------------------------------------------------------------------------
  def test_filtered_count_absent_attendance_records
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Set LLM_PROVIDER (lmstudio | openai | anthropic) to run" unless ENV["LLM_PROVIDER"]
    skip "openai/anthropic require LLM_API_KEY" if %w[openai anthropic].include?(ENV["LLM_PROVIDER"]) && ENV["LLM_API_KEY"].to_s.empty?
    configure_llm_provider!

    with_school_fixtures do |subjects, teachers, students, assignments, exams, attendance|
      agent = Parse::Agent.new(permissions: :readonly)
      openai_tools = fetch_openai_tools(agent)

      prompt = build_school_prompt(
        "How many attendance records have status 'absent'? " \
        "Answer in ONE sentence: \"There are <N> attendance records with status 'absent'.\"",
        hints: [
          "Call count_objects with EXACTLY these arguments: " \
          "{\"class_name\": \"MCPSchoolAttendance\", \"where\": {\"status\": \"absent\"}}. " \
          "The 'where' field is REQUIRED — omitting it returns 48 (all records), not the filtered count.",
        ]
      )

      transcript = llm_round_trip(prompt: prompt, tools: openai_tools, agent: agent, max_iterations: 8)
      flat       = transcript_text(transcript)
      tool_calls = transcript_tool_names(transcript)

      refute_empty tool_calls, "model must invoke at least one MCP tool; got none"
      assert (tool_calls & %w[count_objects query_class]).any?,
             "model should invoke count_objects or query_class; got #{tool_calls.inspect}"
      assert_match(/\b6\b|six/i, flat,
                   "model must report 6 absent records; got: #{flat[0, 600]}")
    end
  end

  # --------------------------------------------------------------------------
  # Test 5: Schema introspection — list all MCPSchool* class names.
  #
  # The LLM must call get_all_schemas and identify the 6 MCPSchool* classes.
  # Ground truth: MCPSchoolSubject, MCPSchoolTeacher, MCPSchoolStudent,
  # MCPSchoolAssignment, MCPSchoolExam, MCPSchoolAttendance.
  # --------------------------------------------------------------------------
  def test_schema_introspection_lists_mcp_school_classes
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Set LLM_PROVIDER (lmstudio | openai | anthropic) to run" unless ENV["LLM_PROVIDER"]
    skip "openai/anthropic require LLM_API_KEY" if %w[openai anthropic].include?(ENV["LLM_PROVIDER"]) && ENV["LLM_API_KEY"].to_s.empty?
    configure_llm_provider!

    with_school_fixtures do |subjects, teachers, students, assignments, exams, attendance|
      agent = Parse::Agent.new(permissions: :readonly)
      openai_tools = fetch_openai_tools(agent)

      prompt = build_school_prompt(
        "List all database class names that start with 'MCPSchool'. " \
        "Answer in ONE sentence listing all such class names separated by commas.",
        hints: [
          "Call get_all_schemas to retrieve all class names, then filter for names starting with 'MCPSchool'.",
        ]
      )

      transcript = llm_round_trip(prompt: prompt, tools: openai_tools, agent: agent, max_iterations: 8)
      flat       = transcript_text(transcript)
      tool_calls = transcript_tool_names(transcript)

      refute_empty tool_calls, "model must invoke at least one MCP tool; got none"
      assert tool_calls.include?("get_all_schemas"),
             "model must call get_all_schemas; got #{tool_calls.inspect}"
      %w[MCPSchoolSubject MCPSchoolTeacher MCPSchoolStudent
         MCPSchoolAssignment MCPSchoolExam MCPSchoolAttendance].each do |class_name|
        assert_match(/#{Regexp.escape(class_name)}/i, flat,
                     "model must list #{class_name} among MCPSchool classes; got: #{flat[0, 600]}")
      end
    end
  end

  private

  # --------------------------------------------------------------------------
  # Schema cleanup helper
  # --------------------------------------------------------------------------

  # Drop MCPSchool* class schemas (if they exist) so that Parse Server
  # re-infers column types from scratch on the next insert.  Parse Server
  # keeps type metadata permanently; a column that was once a String cannot
  # later accept a Pointer without first dropping the schema.  This is safe
  # because reset_database! (called from setup) already deleted all objects
  # in those classes, leaving them empty — and Parse Server only allows
  # schema deletion on empty classes.
  def drop_mcp_school_schemas!
    client = Parse::Client.client
    MCP_SCHOOL_CLASSES.each do |class_name|
      begin
        client.request(:delete, "schemas/#{class_name}", opts: { use_master_key: true })
      rescue StandardError
        # Ignore "class not found" or other non-fatal errors; the schema
        # simply may not exist yet on a fresh server.
      end
    end
  end

  # --------------------------------------------------------------------------
  # Prompt helper
  # --------------------------------------------------------------------------

  # Prepends a compact schema-hint block so individual tests do not repeat
  # the field-listing boilerplate. The `hints:` array adds per-test guidance
  # about which tool to call first and how to format pointer constraints.
  def build_school_prompt(question, hints: [])
    hint_block = hints.empty? ? "" : hints.map { |h| "Hint: #{h}" }.join("\n") + "\n\n"

    <<~PROMPT
      You query a Parse database with MCP tools. Schema:
        MCPSchoolSubject    fields: name (string), department (string), level (string)
        MCPSchoolTeacher    fields: name (string), rating (float), years_experience (integer), subject (Pointer->MCPSchoolSubject)
        MCPSchoolStudent    fields: name (string), grade (integer), teacher (Pointer->MCPSchoolTeacher)
        MCPSchoolAssignment fields: title (string), total_points (integer), due_date (Date), subject (Pointer->MCPSchoolSubject)
        MCPSchoolExam       fields: title (string), max_score (integer), exam_date (Date), subject (Pointer->MCPSchoolSubject)
        MCPSchoolAttendance fields: status (string: "present"|"absent"|"late"), attendance_date (Date), student (Pointer->MCPSchoolStudent), subject (Pointer->MCPSchoolSubject)

      Pointer where-clause format (use this EXACT structure when filtering by a pointer):
        { "<field>": { "__type": "Pointer", "className": "<ClassName>", "objectId": "<id>" } }

      To expand pointer fields inline, pass include: ["<field>"] to query_class or get_object.

      #{hint_block}Question: #{question}
      Use tools to find the answer. Do not guess.
    PROMPT
  end

  # --------------------------------------------------------------------------
  # Transcript helpers
  # --------------------------------------------------------------------------

  def transcript_text(transcript)
    transcript.map { |m| m[:content].to_s }.compact.join(" ")
  end

  def transcript_tool_names(transcript)
    transcript.flat_map { |m| Array(m[:tool_calls]).map { |tc| tc[:name] } }
  end

  # --------------------------------------------------------------------------
  # MCP / tool helpers
  # --------------------------------------------------------------------------

  def fetch_openai_tools(agent)
    envelope = mcp_call({ "jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => {} }, agent)
    tools    = envelope.dig("result", "tools")
    refute_nil tools, "tools/list returned no tools"
    mcp_tools_to_openai(tools)
  end

  # --------------------------------------------------------------------------
  # Provider plumbing
  # --------------------------------------------------------------------------

  def configure_llm_provider!
    @provider = ENV["LLM_PROVIDER"]
    case @provider
    when "lmstudio"
      @base_url = ENV["LLM_BASE_URL"] || "http://localhost:1234/v1"
      @model    = ENV["LLM_MODEL"]    || "qwen2.5-7b-instruct"
      @api_key  = ENV["LLM_API_KEY"]  || "lm-studio"
    when "openai"
      @base_url = ENV["LLM_BASE_URL"] || "https://api.openai.com/v1"
      @model    = ENV["LLM_MODEL"]    || "gpt-4o-mini"
      @api_key  = ENV["LLM_API_KEY"]
    when "anthropic"
      @base_url = ENV["LLM_BASE_URL"] || "https://api.anthropic.com/v1"
      @model    = ENV["LLM_MODEL"]    || "claude-haiku-4-5"
      @api_key  = ENV["LLM_API_KEY"]
    else
      skip "Unknown LLM_PROVIDER=#{@provider.inspect}"
    end
  end

  # --------------------------------------------------------------------------
  # In-process MCP dispatch (real agent, real Parse)
  # --------------------------------------------------------------------------

  def mcp_call(body, agent)
    Parse::Agent::MCPDispatcher.call(body: body, agent: agent)[:body]
  end

  def mcp_tools_to_openai(tools)
    tools.map do |t|
      # MCPDispatcher returns symbol-keyed tool descriptors in-process; on
      # the JSON-RPC wire they are stringified by JSON.generate. Read both.
      h = t.transform_keys(&:to_s)
      {
        type: "function",
        function: {
          name:        h["name"],
          description: h["description"].to_s[0, 1024],
          parameters:  h["inputSchema"] || { "type" => "object", "properties" => {} },
        },
      }
    end
  end

  # --------------------------------------------------------------------------
  # LLM round-trip
  # --------------------------------------------------------------------------

  def llm_round_trip(prompt:, tools:, agent:, max_iterations: 6)
    messages   = [{ role: "user", content: prompt }]
    transcript = []

    max_iterations.times do
      reply = call_llm(messages: messages, tools: tools)
      transcript << reply
      messages << { role: "assistant", content: reply[:content], tool_calls: reply[:tool_calls] }

      break if reply[:tool_calls].nil? || reply[:tool_calls].empty?

      reply[:tool_calls].each do |tc|
        body = {
          "jsonrpc" => "2.0",
          "id"      => SecureRandom.hex(4),
          "method"  => "tools/call",
          "params"  => { "name" => tc[:name], "arguments" => tc[:arguments] },
        }
        result    = mcp_call(body, agent)
        tool_text = if result["result"]
          result.dig("result", "content", 0, "text") || result["result"].to_json
        else
          result.dig("error", "message").to_s
        end
        messages << { role: "tool", tool_call_id: tc[:id], content: tool_text }
      end
    end

    transcript
  end

  def call_llm(messages:, tools:)
    case @provider
    when "anthropic" then anthropic_chat(messages: messages, tools: tools)
    else                  openai_chat(messages: messages, tools: tools)
    end
  end

  def openai_chat(messages:, tools:)
    # Translate test-internal message shape -> OpenAI wire shape.
    openai_messages = messages.map do |m|
      case m[:role]
      when "user", "system"
        { role: m[:role], content: m[:content].to_s }
      when "assistant"
        out = { role: "assistant", content: m[:content] }
        if m[:tool_calls] && !m[:tool_calls].empty?
          out[:tool_calls] = m[:tool_calls].map do |tc|
            args_str = tc[:arguments].is_a?(String) ? tc[:arguments] : JSON.generate(tc[:arguments] || {})
            { id: tc[:id], type: "function", function: { name: tc[:name], arguments: args_str } }
          end
        end
        out
      when "tool"
        { role: "tool", tool_call_id: m[:tool_call_id], content: m[:content].to_s }
      end
    end.compact

    uri  = URI("#{@base_url}/chat/completions")
    body = JSON.generate({ model: @model, messages: openai_messages, tools: tools, tool_choice: "auto" })

    req = Net::HTTP::Post.new(uri)
    req["Content-Type"]  = "application/json"
    req["Authorization"] = "Bearer #{@api_key}"
    req.body = body

    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", read_timeout: 90) { |h| h.request(req) }
    skip "LLM call failed: HTTP #{res.code} #{res.body[0, 300]}" unless res.code.to_i.between?(200, 299)

    parsed = JSON.parse(res.body)
    msg    = parsed.dig("choices", 0, "message") || {}
    calls  = Array(msg["tool_calls"]).map do |tc|
      args = tc.dig("function", "arguments")
      args = JSON.parse(args) if args.is_a?(String) && !args.empty?
      { id: tc["id"] || SecureRandom.hex(4), name: tc.dig("function", "name"), arguments: args || {} }
    end
    { role: "assistant", content: msg["content"], tool_calls: calls }
  end

  def anthropic_chat(messages:, tools:)
    anth_tools    = tools.map { |t| { name: t[:function][:name], description: t[:function][:description], input_schema: t[:function][:parameters] } }
    anth_messages = messages.map do |m|
      case m[:role]
      when "user", "assistant" then { role: m[:role], content: m[:content].to_s }
      when "tool"              then { role: "user",   content: [{ type: "tool_result", tool_use_id: m[:tool_call_id], content: m[:content] }] }
      end
    end.compact

    uri  = URI("#{@base_url}/messages")
    body = JSON.generate({ model: @model, max_tokens: 1024, tools: anth_tools, messages: anth_messages })

    req = Net::HTTP::Post.new(uri)
    req["Content-Type"]      = "application/json"
    req["x-api-key"]         = @api_key
    req["anthropic-version"] = "2023-06-01"
    req.body = body

    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", read_timeout: 90) { |h| h.request(req) }
    skip "Anthropic call failed: HTTP #{res.code} #{res.body[0, 300]}" unless res.code.to_i.between?(200, 299)

    parsed = JSON.parse(res.body)
    blocks = Array(parsed["content"])
    text   = blocks.select { |b| b["type"] == "text" }.map { |b| b["text"] }.join("\n")
    calls  = blocks.select { |b| b["type"] == "tool_use" }.map { |b| { id: b["id"], name: b["name"], arguments: b["input"] || {} } }
    { role: "assistant", content: text, tool_calls: calls }
  end
end
