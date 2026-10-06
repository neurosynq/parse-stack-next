require_relative "../../test_helper"

# Unit coverage for batch save/destroy correctness: transactions sent as one
# atomic request, responses aligned to their requests when a chunk fails, a
# malformed response never counted as success, per-object outcome handling,
# no dedup of distinct writes, local state after Array#destroy, timestamps and
# array proxies after a batch create, success bodies that carry `code` or
# `error` columns, and Array#save / #destroy on arrays with no Parse objects.
class BatchAuditWidget < Parse::Object
  parse_class "BatchAuditWidget"
  property :name, :string
  property :n, :integer
  property :list, :array
  has_many :tags, through: :relation, as: :batch_audit_widget
end

class BatchAuditTest < Minitest::Test
  CREATED = "2026-01-01T00:00:00.000Z".freeze
  UPDATED = "2026-01-02T00:00:00.000Z".freeze

  # One fake client shared by every test: model classes memoize their client,
  # so swapping the instance per test would leave them pointing at a stale one.
  FAKE_CLIENT = Parse::Client.allocate.tap do |c|
    conn = Faraday.new(url: "http://localhost:1/parse")
    c.instance_variable_set(:@conn, conn)
    c.instance_variable_set(:@retry_limit, 0)
  end

  def setup
    @saved_default = Parse::Client.clients[:default]
    Parse::Client.clients[:default] = FAKE_CLIENT
    BatchAuditWidget.instance_variable_set(:@client, FAKE_CLIENT)
    @calls = []
    @responder = ->(_body) { raise "no responder set" }
    calls = @calls
    test = self
    FAKE_CLIENT.define_singleton_method(:request) do |_method, _path = nil, body: nil, **_opts|
      calls << body
      test.instance_variable_get(:@responder).call(body)
    end
  end

  def teardown
    FAKE_CLIENT.singleton_class.send(:remove_method, :request)
    if @saved_default
      Parse::Client.clients[:default] = @saved_default
    else
      Parse::Client.clients.delete(:default)
    end
  end

  def requests_in(body)
    body["requests"] || body[:requests]
  end

  def created_for_all
    lambda do |body|
      Parse::Response.new(requests_in(body).each_with_index.map do |r, i|
        name = (r["body"] || {})["name"]
        { "success" => { "objectId" => "ID_#{name || i}", "createdAt" => CREATED } }
      end)
    end
  end

  def existing(id, attrs = {})
    Parse::Object.build(
      { "objectId" => id, "name" => "a", "createdAt" => CREATED, "updatedAt" => CREATED }.merge(attrs),
      "BatchAuditWidget",
    )
  end

  # --- B1 / R1: transactions -----------------------------------------------

  def test_transaction_is_sent_as_one_request_with_the_flag
    @responder = created_for_all
    objs = 60.times.map { |i| BatchAuditWidget.new(name: "t#{i}") }
    batch = Parse::BatchOperation.new(nil, transaction: true)
    objs.each { |o| batch.add(o) }
    responses = batch.submit

    assert_equal 1, @calls.size, "a transaction must never be split into several batches"
    assert_equal 60, requests_in(@calls.first).size
    assert_equal true, @calls.first["transaction"]
    assert_equal 60, responses.size
  end

  def test_transaction_error_marks_every_request_failed
    @responder = ->(_b) { Parse::Response.error_response(142, "rejected") }
    batch = Parse::BatchOperation.new(nil, transaction: true)
    3.times { |i| batch.add(BatchAuditWidget.new(name: "x#{i}")) }
    responses = batch.submit
    assert_equal 3, responses.size
    assert responses.none?(&:success?)
    assert_equal [142, 142, 142], responses.map(&:code)
  end

  def test_transaction_exception_propagates_without_partial_state
    @responder = ->(_b) { raise Parse::Error::ServiceUnavailableError, "boom" }
    batch = Parse::BatchOperation.new(nil, transaction: true)
    batch.add(BatchAuditWidget.new(name: "x"))
    assert_raises(Parse::Error::ServiceUnavailableError) { batch.submit }
  end

  # --- B3: chunk failure does not shift responses --------------------------

  def test_http_error_on_one_chunk_does_not_shift_other_responses
    @responder = lambda do |body|
      reqs = requests_in(body)
      if reqs.first["body"]["name"] == "w0"
        Parse::Response.error_response(155, "rate limited")
      else
        created_for_all.call(body)
      end
    end
    objs = 60.times.map { |i| BatchAuditWidget.new(name: "w#{i}") }
    batch = objs.save

    assert_equal 60, batch.responses.size
    (0...50).each { |i| assert_nil objs[i].id, "w#{i} was in the failed chunk" }
    (50...60).each { |i| assert_equal "ID_w#{i}", objs[i].id }
    assert batch.error?
  end

  def test_exception_in_one_chunk_still_applies_other_chunks_then_raises
    @responder = lambda do |body|
      reqs = requests_in(body)
      raise Parse::Error::ServiceUnavailableError, "down" if reqs.first["body"]["name"] == "e0"
      created_for_all.call(body)
    end
    objs = 60.times.map { |i| BatchAuditWidget.new(name: "e#{i}") }
    assert_raises(Parse::Error::ServiceUnavailableError) { objs.save }
    assert_nil objs[0].id
    assert_equal "ID_e55", objs[55].id, "a landed create must not be left looking new"
    refute objs[55].new?
  end

  # --- B4: malformed / short responses -------------------------------------

  def test_short_batch_response_fails_the_missing_entries
    @responder = lambda do |body|
      reqs = requests_in(body)
      Parse::Response.new(reqs.first(reqs.size - 1).map do |r|
        { "success" => { "objectId" => "ID_#{r["body"]["name"]}", "createdAt" => CREATED } }
      end)
    end
    objs = 3.times.map { |i| BatchAuditWidget.new(name: "f#{i}") }
    batch = objs.save
    assert_equal %w[ID_f0 ID_f1], objs.first(2).map(&:id)
    assert_nil objs.last.id
    assert objs.last.changed?
    refute batch.success?
    assert batch.error?
  end

  def test_non_array_success_body_is_a_failure
    @responder = ->(_b) { Parse::Response.new({}) }
    objs = 2.times.map { |i| BatchAuditWidget.new(name: "g#{i}") }
    batch = objs.save
    assert_equal [nil, nil], objs.map(&:id)
    assert objs.all?(&:changed?)
    refute batch.success?
  end

  def test_malformed_entries_are_failures
    resp = Parse::Response.new([{ "success" => { "objectId" => "a" } }, "junk", {}, { "error" => "text" }])
    entries = resp.batch_responses
    assert entries.first.success?
    assert entries[1..].none?(&:success?)
  end

  # --- B5: two requests for one object --------------------------------------

  def test_failed_attribute_write_survives_successful_relation_write
    @responder = lambda do |body|
      Parse::Response.new(requests_in(body).map do |r|
        if r["body"].key?("name")
          { "error" => { "code" => 142, "error" => "rejected name" } }
        else
          { "success" => { "updatedAt" => UPDATED } }
        end
      end)
    end
    tag = existing("T1")
    x = existing("X9")
    x.name = "new-name"
    x.tags.add(tag)
    batch = [x].save

    refute batch.success?
    assert x.changed?, "the failed attribute write must stay dirty"
    assert_equal "new-name", x.name
    assert_equal [{ "name" => "new-name" }], x.change_requests.map { |r| r.body.as_json }
  end

  def test_failed_relation_write_survives_successful_attribute_write
    @responder = lambda do |body|
      Parse::Response.new(requests_in(body).map do |r|
        if r["body"].key?("tags")
          { "error" => { "code" => 111, "error" => "bad relation" } }
        else
          { "success" => { "updatedAt" => UPDATED } }
        end
      end)
    end
    x = existing("X8")
    x.name = "renamed"
    x.tags.add(existing("T2"))
    [x].save
    assert x.relation_changes?, "the failed relation write must stay pending"
    refute x.name_changed?, "the successful attribute write is cleared"
  end

  # --- B7 / R2: no dedup of distinct writes ---------------------------------

  def test_identical_raw_increments_are_both_sent
    @responder = ->(body) { Parse::Response.new(requests_in(body).map { { "success" => { "updatedAt" => UPDATED } } }) }
    batch = Parse::BatchOperation.new
    2.times { batch.add(Parse::Request.new(:put, "/parse/classes/BatchAuditWidget/C1", body: { n: { __op: "Increment", amount: 1 } })) }
    batch.submit
    assert_equal 2, requests_in(@calls.last).size
  end

  def test_distinct_new_objects_with_identical_fields_are_both_created
    @responder = lambda do |body|
      Parse::Response.new(requests_in(body).each_with_index.map { |_r, i| { "success" => { "objectId" => "X#{i}", "createdAt" => CREATED } } })
    end
    a = BatchAuditWidget.new(name: "same")
    b = BatchAuditWidget.new(name: "same")
    [a, b].save
    assert_equal 2, requests_in(@calls.last).size
    assert_equal %w[X0 X1], [a.id, b.id]
    refute b.changed?
  end

  def test_same_object_listed_twice_is_saved_once
    @responder = ->(body) { Parse::Response.new(requests_in(body).map { { "success" => { "updatedAt" => UPDATED } } }) }
    e = existing("E1")
    e.name = "z"
    [e, e].save
    assert_equal 1, requests_in(@calls.last).size
  end

  def test_object_added_twice_to_a_batch_is_sent_once
    obj = BatchAuditWidget.new(name: "once")
    batch = Parse::BatchOperation.new
    batch.add(obj)
    batch.add(obj)
    assert_equal 1, batch.count
  end

  # --- B11: Array#destroy updates local state --------------------------------

  def test_array_destroy_updates_destroyed_objects_only
    @responder = lambda do |body|
      Parse::Response.new(requests_in(body).map do |r|
        r["path"].end_with?("D1") ? { "error" => { "code" => 101, "error" => "nope" } } : { "success" => {} }
      end)
    end
    objs = %w[D0 D1 D2].map { |id| existing(id) }
    batch = objs.destroy
    assert_equal [true, false, true], objs.map(&:destroyed?)
    assert_equal %w[D0 D1 D2], objs.map(&:id), "ids are kept, as with Parse::Object#destroy"
    assert_equal [true, false, true], batch.responses.map(&:success?)
  end

  # --- B12: timestamps and array proxies after a batch save ------------------

  def test_batch_create_sets_updated_at
    @responder = created_for_all
    o = BatchAuditWidget.new(name: "ts")
    [o].save
    refute_nil o.created_at
    assert_equal o.created_at, o.updated_at
  end

  def test_batch_save_settles_array_proxy
    @responder = ->(body) { Parse::Response.new(requests_in(body).map { { "success" => { "updatedAt" => UPDATED } } }) }
    o = existing("A1", "list" => ["a"])
    o.list.add("b")
    [o].save
    refute o.list.changed?, "array proxy must not stay dirty after a successful save"
    assert_empty o.change_requests
  end

  # --- B13: success bodies with `code` / `error` columns ----------------------

  def test_success_entry_with_code_column_is_success
    @responder = lambda do |body|
      Parse::Response.new(requests_in(body).map do
        { "success" => { "objectId" => "C1", "createdAt" => CREATED, "code" => "SKU-1", "error" => "none" } }
      end)
    end
    o = BatchAuditWidget.new(name: "coded")
    batch = [o].save
    assert batch.success?
    assert_equal "C1", o.id
    refute o.changed?
  end

  # --- #29: arrays without Parse objects --------------------------------------

  def test_save_on_non_parse_array_raises
    assert_raises(ArgumentError) { [1, 2].save }
    assert_raises(ArgumentError) { [{ a: 1 }].destroy }
    assert_empty @calls
  end

  def test_save_on_empty_array_is_a_successful_no_op
    batch = [].save
    assert batch.success?
    refute batch.error?
    assert_empty @calls
  end

  def test_mixed_array_skips_non_parse_elements
    @responder = created_for_all
    o = BatchAuditWidget.new(name: "mixed")
    [o, "not a model", 3].save
    assert_equal "ID_mixed", o.id
  end
end
