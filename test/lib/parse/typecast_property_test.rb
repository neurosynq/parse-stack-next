require_relative "../../test_helper"

# Property typecasting and change tracking for mutable values. Each test
# pins a case that previously lost or corrupted data silently.
class TypecastPropertyModel < Parse::Object
  parse_class "TypecastPropertyModel"

  property :meta, :object
  property :list, :array
  property :labels, :array, symbolize: true
  property :when, :date
  property :count, :integer
  property :ratio, :float
  property :amount, :number
  property :title, :string
  property :flag, :boolean
  property :location, :geopoint
  property :tel, :phone
end

class TypecastPropertyTest < Minitest::Test
  def setup
    @obj = TypecastPropertyModel.new
    @obj.instance_variable_set(:@id, "tc123")
    @obj.instance_variable_set(:@created_at, Time.now)
    @obj.clear_changes!
  end

  def hydrate(attrs)
    obj = TypecastPropertyModel.new
    obj.instance_variable_set(:@id, "tc456")
    obj.instance_variable_set(:@created_at, Time.now)
    obj.apply_attributes!(attrs, dirty_track: false)
    obj.clear_changes!
    obj
  end

  # ------------------------------------------------------------------
  # In-place edits to :object and :array values
  # ------------------------------------------------------------------

  def test_in_place_hash_edit_is_detected_and_sent
    obj = hydrate("meta" => { "a" => 1 })
    refute obj.changed?, "reading alone must not dirty the record"
    obj.meta["k"] = 1
    assert obj.changed?
    assert obj.meta_changed?
    assert_equal({ "a" => 1, "k" => 1 }, obj.attribute_updates[:meta].to_h)
    assert_equal [{ "a" => 1 }, { "a" => 1, "k" => 1 }], obj.changes["meta"].map(&:to_h)
  end

  def test_nested_in_place_edit_is_detected
    obj = hydrate("meta" => { "inner" => { "x" => 1 }, "rows" => [{ "v" => 1 }] })
    obj.meta["inner"]["x"] = 2
    assert obj.meta_changed?
    obj.clear_changes!
    refute obj.changed?
    obj.meta["rows"][0]["v"] = 5
    assert obj.meta_changed?
  end

  def test_in_place_hash_edit_rolls_back
    obj = hydrate("meta" => { "a" => 1 })
    obj.meta["a"] = 99
    obj.rollback!
    assert_equal({ "a" => 1 }, obj.meta.to_h)
    refute obj.changed?
  end

  def test_in_place_edit_baseline_moves_after_changes_applied
    obj = hydrate("meta" => { "a" => 1 })
    obj.meta["a"] = 2
    assert obj.changed?
    obj.changes_applied!
    refute obj.changed?, "a saved value is the new baseline"
    obj.meta["a"] = 3
    assert obj.changed?
  end

  def test_held_reference_edit_after_save_is_detected
    obj = hydrate("meta" => { "a" => 1 })
    held = obj.meta
    obj.changes_applied!
    held["b"] = 2
    assert obj.meta_changed?
  end

  def test_in_place_edit_of_hash_inside_array_is_detected
    obj = hydrate("list" => [{ "v" => 1 }])
    obj.list.first["v"] = 2
    assert obj.list_changed?
    assert_equal [{ "v" => 2 }], obj.attribute_updates[:list]
  end

  def test_hydration_does_not_mark_dirty
    obj = hydrate("meta" => { "a" => 1 }, "list" => [1, 2])
    obj.meta
    obj.list
    obj.apply_attributes!({ "meta" => { "a" => 2 } }, dirty_track: false)
    refute obj.changed?
  end

  def test_object_assignment_does_not_alias_caller_hash
    source = { "a" => { "b" => 1 } }
    @obj.meta = source
    @obj.meta["a"]["b"] = 2
    assert_equal 1, source["a"]["b"]
  end

  # ------------------------------------------------------------------
  # :array values
  # ------------------------------------------------------------------

  def test_array_keeps_nil_elements
    @obj.list = [1, nil, 3]
    assert_equal [1, nil, 3], @obj.list.to_a
    assert_equal [1, nil, 3], @obj.attribute_updates[:list]
  end

  def test_symbolized_array_keeps_nil_elements
    @obj.labels = ["a", nil, "b"]
    assert_equal [:a, nil, :b], @obj.labels.to_a
  end

  def test_nil_array_assignment_is_empty
    @obj.list = nil
    assert_equal [], @obj.list.to_a
  end

  def test_array_assignment_does_not_alias_caller_array
    source = ["a"]
    obj = TypecastPropertyModel.new(list: source)
    obj.list.add("b")
    assert_equal ["a"], source
  end

  def test_array_change_history_keeps_previous_value
    @obj.list = ["a"]
    @obj.clear_changes!
    @obj.list.add("b")
    previous, current = @obj.changes["list"]
    assert_equal ["a"], previous.to_a
    assert_equal ["a", "b"], current.to_a
  end

  def test_array_rollback_restores_previous_value
    @obj.list = ["a"]
    @obj.clear_changes!
    @obj.list.add("b")
    @obj.list.remove("a")
    @obj.rollback!
    assert_equal ["a"], @obj.list.to_a
    refute @obj.changed?
  end

  def test_collection_proxy_copy_has_its_own_array
    proxy = Parse::CollectionProxy.new([1, 2])
    copy = proxy.clone
    proxy.add(3)
    assert_equal [1, 2], copy.to_a
  end

  # ------------------------------------------------------------------
  # Dates nested in :array and :object values
  # ------------------------------------------------------------------

  def test_nested_dates_are_sent_as_parse_dates
    time = Time.utc(2024, 1, 2, 3, 4, 5)
    @obj.list = [time, "plain"]
    @obj.meta = { "at" => DateTime.new(2024, 1, 2), "deep" => [{ "d" => Parse::Date.parse("2024-05-06T00:00:00Z") }] }
    updates = @obj.attribute_updates
    assert_equal({ "__type" => "Date", "iso" => "2024-01-02T03:04:05.000Z" }, updates[:list][0])
    assert_equal "plain", updates[:list][1]
    assert_equal "Date", updates[:meta]["at"]["__type"]
    assert_equal({ "__type" => "Date", "iso" => "2024-05-06T00:00:00.000Z" }, updates[:meta]["deep"][0]["d"])
    # The local value is not rewritten.
    assert_kind_of Time, @obj.list.first
  end

  # ------------------------------------------------------------------
  # Numeric types
  # ------------------------------------------------------------------

  def test_integer_casts
    @obj.count = ""
    assert_nil @obj.count
    @obj.count = "  "
    assert_nil @obj.count
    @obj.count = "42"
    assert_equal 42, @obj.count
    @obj.count = "5.0"
    assert_equal 5, @obj.count
    @obj.count = 7.9
    assert_equal 7, @obj.count
  end

  def test_integer_refuses_lossy_or_meaningless_values
    [true, false, "1.5", "abc", Float::NAN, Float::INFINITY, [1]].each do |bad|
      assert_raises(Parse::Properties::TypecastError, "should refuse #{bad.inspect}") { @obj.count = bad }
    end
  end

  def test_refused_integer_never_emits_delete
    @obj.count = 3
    @obj.clear_changes!
    assert_raises(Parse::Properties::TypecastError) { @obj.count = true }
    assert_equal 3, @obj.count
    refute @obj.attribute_updates.key?(:count)
  end

  def test_float_casts
    @obj.ratio = ""
    assert_nil @obj.ratio
    @obj.ratio = "1.25"
    assert_equal 1.25, @obj.ratio
    @obj.ratio = 2
    assert_equal 2.0, @obj.ratio
    [true, false, "abc", Float::NAN, -Float::INFINITY].each do |bad|
      assert_raises(Parse::Properties::TypecastError, "should refuse #{bad.inspect}") { @obj.ratio = bad }
    end
  end

  def test_number_casts
    @obj.amount = ""
    assert_nil @obj.amount
    @obj.amount = "4.5"
    assert_equal 4.5, @obj.amount
    @obj.amount = "5.0"
    assert_equal 5, @obj.amount
    [true, "abc", Float::NAN].each do |bad|
      assert_raises(Parse::Properties::TypecastError, "should refuse #{bad.inspect}") { @obj.amount = bad }
    end
  end

  def test_untracked_hydration_keeps_unconvertible_value
    obj = hydrate("count" => "abc", "ratio" => true)
    assert_equal "abc", obj.count
    assert_equal true, obj.ratio
    refute obj.changed?
  end

  def test_nil_still_clears_numeric_column
    @obj.count = 1
    @obj.clear_changes!
    @obj.count = nil
    assert_equal({ __op: :Delete }, @obj.attribute_updates[:count])
  end

  # ------------------------------------------------------------------
  # :string, :boolean, :date
  # ------------------------------------------------------------------

  def test_string_casts_false_and_refuses_containers
    @obj.title = false
    assert_equal "false", @obj.title
    @obj.title = ""
    assert_equal "", @obj.title
    assert_raises(Parse::Properties::TypecastError) { @obj.title = [] }
    assert_raises(Parse::Properties::TypecastError) { @obj.title = {} }
  end

  def test_boolean_no_and_n_are_false
    %w[no n NO N].each do |v|
      @obj.flag = v
      assert_equal false, @obj.flag, "#{v.inspect} should be false"
    end
    @obj.flag = "yes"
    assert_equal true, @obj.flag
  end

  def test_date_refuses_numeric
    assert_raises(Parse::Properties::TypecastError) { @obj.when = 1_700_000_000 }
    @obj.when = Time.at(1_700_000_000).utc
    assert_kind_of Parse::Date, @obj.when
  end

  # ------------------------------------------------------------------
  # GeoPoint
  # ------------------------------------------------------------------

  def test_geopoint_keyword_and_hash_forms
    [
      Parse::GeoPoint.new(lat: 10, lng: 20),
      Parse::GeoPoint.new(latitude: 10, longitude: 20),
      Parse::GeoPoint.new({ lat: 10, lng: 20 }),
      Parse::GeoPoint.new({ "lat" => 10, "lng" => 20 }),
      Parse::GeoPoint.new({ "__type" => "GeoPoint", "latitude" => 10, "longitude" => 20 }),
      Parse::GeoPoint.new("10", "20"),
      Parse::GeoPoint.new("10, 20"),
      Parse::GeoPoint.new([10, 20]),
    ].each do |gp|
      assert_equal [10.0, 20.0], gp.to_a
    end
  end

  def test_geopoint_property_accepts_lat_lng_hash
    @obj.location = { lat: 32.5, lng: -117.25 }
    assert_equal [32.5, -117.25], @obj.location.to_a
  end

  def test_geopoint_refuses_garbage
    assert_raises(ArgumentError) { Parse::GeoPoint.new("abc", "def") }
    assert_raises(ArgumentError) { Parse::GeoPoint.new(lat: "abc", lng: 1) }
    assert_raises(ArgumentError) { Parse::GeoPoint.new(10, nil) }
    assert_raises(ArgumentError) { Parse::GeoPoint.new(Float::NAN, 1) }
    assert_raises(ArgumentError) { Parse::GeoPoint.new([1]) }
  end

  def test_geopoint_partial_hash_keeps_other_coordinate
    gp = Parse::GeoPoint.new(1, 2)
    gp.attributes = { lat: 5 }
    assert_equal [5.0, 2.0], gp.to_a
  end

  # ------------------------------------------------------------------
  # Phone
  # ------------------------------------------------------------------

  def test_us_numbers_get_plus_one
    ["4155551234", "(415) 555-1234", "415.555.1234", "14155551234", "1-415-555-1234"].each do |raw|
      assert_equal "+14155551234", Parse::Phone.new(raw).to_s, raw
    end
    assert Parse::Phone.new("(415) 555-1234").valid?
    assert_equal "1", Parse::Phone.new("(415) 555-1234").country_code
  end

  def test_explicit_plus_and_international_prefix_are_kept
    assert_equal "+41555512345", Parse::Phone.new("+41 55 551 23 45").to_s
    assert_equal "+442071234567", Parse::Phone.new("00442071234567").to_s
    assert_equal "+442071234567", Parse::Phone.new("442071234567").to_s
  end

  def test_phone_default_country_code_is_configurable
    original = Parse::Phone.default_country_code
    Parse::Phone.default_country_code = "44"
    assert_equal "+442071234567", Parse::Phone.new("020 7123 4567").to_s
    Parse::Phone.default_country_code = nil
    phone = Parse::Phone.new("4155551234")
    refute phone.valid?, "no country assumption means an unprefixed national number is invalid"
  ensure
    Parse::Phone.default_country_code = original
  end

  # ------------------------------------------------------------------
  # Bytes and File
  # ------------------------------------------------------------------

  def test_bytes_encode_is_strict_and_attributes_assign
    bytes = Parse::Bytes.new
    bytes.encode("x" * 100)
    refute_includes bytes.base64, "\n"
    assert_equal "x" * 100, bytes.decoded
    bytes.attributes = { "__type" => "Bytes", "base64" => "Zm9v" }
    assert_equal "foo", bytes.decoded
    bytes.attributes = "YmFy"
    assert_equal "bar", bytes.decoded
  end

  def test_hydrated_file_has_no_guessed_mime_type
    file = Parse::File.new({ "__type" => "File", "name" => "doc.pdf", "url" => "https://files.example.com/doc.pdf" })
    assert_nil file.mime_type
    upload = Parse::File.new("notes.txt", "hello")
    assert_equal Parse::File.default_mime_type, upload.mime_type
    copy = Parse::File.new(Parse::File.new("a.txt", "x", "text/plain"))
    assert_equal "text/plain", copy.mime_type
  end

  def test_file_inspect_reports_contents_presence
    assert_includes Parse::File.new("a.txt", "x").inspect, "@contents=true"
    hydrated = Parse::File.new({ "name" => "a.txt", "url" => "https://files.example.com/a.txt" })
    assert_includes hydrated.inspect, "@contents=false"
  end
end
