require_relative "../../../test_helper"

class TestWhereNotBetween < Minitest::Test
  class NotBetweenPerson < Parse::Object
    parse_class "NotBetweenPerson"
    property :age, :integer
    property :name, :string
  end

  def compiled_where(query)
    query.compile(encode: false).as_json["where"]
  end

  def test_inclusive_range
    where = compiled_where(NotBetweenPerson.query.where_not_between(:age, 5..25))
    assert_equal({ "$or" => [{ "age" => { "$lt" => 5 } }, { "age" => { "$gt" => 25 } }] }, where)
  end

  def test_exclusive_range_flips_upper_bound_to_gte
    where = compiled_where(NotBetweenPerson.query.where_not_between(:age, 5...25))
    assert_equal({ "$or" => [{ "age" => { "$lt" => 5 } }, { "age" => { "$gte" => 25 } }] }, where)
  end

  def test_array_form_is_always_inclusive
    where = compiled_where(NotBetweenPerson.query.where_not_between(:age, [5, 25]))
    assert_equal({ "$or" => [{ "age" => { "$lt" => 5 } }, { "age" => { "$gt" => 25 } }] }, where)
  end

  def test_beginless_range_has_no_or_wrapper
    where = compiled_where(NotBetweenPerson.query.where_not_between(:age, ..25))
    assert_equal({ "age" => { "$gt" => 25 } }, where)
  end

  def test_endless_range_has_no_or_wrapper
    where = compiled_where(NotBetweenPerson.query.where_not_between(:age, 5..))
    assert_equal({ "age" => { "$lt" => 5 } }, where)
  end

  def test_nests_correctly_alongside_an_unrelated_and_condition
    where = compiled_where(NotBetweenPerson.where(:name => "Bob").where_not_between(:age, 5..25))
    assert_equal "Bob", where["name"]
    assert_equal [{ "age" => { "$lt" => 5 } }, { "age" => { "$gt" => 25 } }], where["$or"]
  end

  def test_raises_on_fully_open_range
    assert_raises(ArgumentError) do
      NotBetweenPerson.query.where_not_between(:age, nil..nil)
    end
  end

  def test_raises_on_invalid_value_type
    assert_raises(ArgumentError) do
      NotBetweenPerson.query.where_not_between(:age, 25)
    end
  end

  def test_raises_on_array_with_wrong_length
    assert_raises(ArgumentError) do
      NotBetweenPerson.query.where_not_between(:age, [5])
    end
  end

  def test_raises_when_query_already_has_an_or_group_from_or_where
    query = NotBetweenPerson.where(:name.eq => "a").or_where(:name.eq => "b")
    assert_raises(ArgumentError) do
      query.where_not_between(:age, 5..25)
    end
  end

  def test_raises_when_query_already_has_an_or_group_from_pipe_operator
    query = NotBetweenPerson.where(:name.eq => "a") | NotBetweenPerson.where(:name.eq => "b")
    assert_raises(ArgumentError) do
      query.where_not_between(:age, 5..25)
    end
  end

  def test_raises_on_second_where_not_between_call
    query = NotBetweenPerson.query.where_not_between(:age, 5..25)
    assert_raises(ArgumentError) do
      query.where_not_between(:name, "a".."m")
    end
  end

  def test_one_sided_form_does_not_trip_the_existing_or_group_guard
    # Beginless/endless negation is a single condition, no new $or is
    # introduced, so it's safe even when the query already has one.
    query = NotBetweenPerson.where(:name.eq => "a").or_where(:name.eq => "b")
    query.where_not_between(:age, 5..)
    where = compiled_where(query)
    assert where["$or"].present?, "the pre-existing $or group must survive"
    assert_equal({ "$lt" => 5 }, where["age"])
  end
end
