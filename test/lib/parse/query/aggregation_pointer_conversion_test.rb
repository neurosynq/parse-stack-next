require_relative "../../../test_helper"

class TestAggregationPointerConversion < Minitest::Test
  
  def setup
    @query = Parse::Query.new("Membership")
  end
  
  def test_convert_constraints_for_aggregation_with_pointer_objects_in_array
    # Test with Parse::Pointer objects - should become _p_team for aggregation
    pointer1 = Parse::Pointer.new("Team", "team1")
    pointer2 = Parse::Pointer.new("Team", "team2")
    
    constraints = {
      "team" => { "$in" => [pointer1, pointer2] }
    }
    
    result = @query.send(:convert_constraints_for_aggregation, constraints)
    
    # For aggregation: team -> _p_team and pointers get converted to MongoDB format
    expected = {
      "_p_team" => { "$in" => ["Team$team1", "Team$team2"] }
    }
    
    assert_equal expected, result
  end
  
  def test_convert_constraints_for_aggregation_with_pointer_hashes_in_array
    # Test with pointer hash objects
    pointer_hash1 = { "__type" => "Pointer", "className" => "Team", "objectId" => "team1" }
    pointer_hash2 = { "__type" => "Pointer", "className" => "Team", "objectId" => "team2" }
    
    constraints = {
      "_p_team" => { "$in" => [pointer_hash1, pointer_hash2] }
    }
    
    result = @query.send(:convert_constraints_for_aggregation, constraints)
    
    expected = {
      "_p_team" => { "$in" => ["Team$team1", "Team$team2"] }
    }
    
    assert_equal expected, result
  end
  
  def test_convert_constraints_for_aggregation_with_string_ids_and_pointers_mixed
    # Test the real scenario: some string IDs mixed with pointer objects
    # This tests the case where we can infer the class name from existing pointers
    pointer_obj = Parse::Pointer.new("Team", "team1")
    string_id = "pSG4jLm105"  # Like your real data
    
    constraints = {
      "team" => { "$in" => [pointer_obj, string_id] }
    }
    
    result = @query.send(:convert_constraints_for_aggregation, constraints)
    
    # The pointer provides class name, so string ID gets converted too
    expected = {
      "_p_team" => { "$in" => ["Team$team1", "Team$pSG4jLm105"] }
    }
    
    assert_equal expected, result
  end
  
  def test_convert_constraints_for_aggregation_with_mixed_array
    # Test with mixed array: Parse::Pointer, hash, and string
    pointer_obj = Parse::Pointer.new("Team", "team1")
    pointer_hash = { "__type" => "Pointer", "className" => "Team", "objectId" => "team2" }
    string_id = "team3"
    
    constraints = {
      "_p_team" => { "$in" => [pointer_obj, pointer_hash, string_id] }
    }
    
    result = @query.send(:convert_constraints_for_aggregation, constraints)
    
    expected = {
      "_p_team" => { "$in" => ["Team$team1", "Team$team2", "Team$team3"] }
    }
    
    assert_equal expected, result
  end
  
  def test_convert_constraints_for_aggregation_with_nin_operator
    # Test $nin operator works the same way
    pointer1 = Parse::Pointer.new("Team", "team1")
    pointer2 = Parse::Pointer.new("Team", "team2")
    
    constraints = {
      "_p_team" => { "$nin" => [pointer1, pointer2] }
    }
    
    result = @query.send(:convert_constraints_for_aggregation, constraints)
    
    expected = {
      "_p_team" => { "$nin" => ["Team$team1", "Team$team2"] }
    }
    
    assert_equal expected, result
  end
  
  def test_convert_constraints_for_aggregation_with_single_pointer_object
    # Test single pointer object (not in array)
    pointer = Parse::Pointer.new("Team", "team1")
    
    constraints = {
      "_p_team" => pointer
    }
    
    result = @query.send(:convert_constraints_for_aggregation, constraints)
    
    expected = {
      "_p_team" => "Team$team1"
    }
    
    assert_equal expected, result
  end
  
  def test_convert_constraints_for_aggregation_with_single_pointer_hash
    # Test single pointer hash (not in array)
    pointer_hash = { "__type" => "Pointer", "className" => "Team", "objectId" => "team1" }
    
    constraints = {
      "_p_team" => pointer_hash
    }
    
    result = @query.send(:convert_constraints_for_aggregation, constraints)
    
    expected = {
      "_p_team" => "Team$team1"
    }
    
    assert_equal expected, result
  end
  
  def test_convert_constraints_for_aggregation_non_pointer_field_unchanged
    # Test that non-pointer fields are not affected
    constraints = {
      "name" => { "$in" => ["video", "audio"] }
    }
    
    result = @query.send(:convert_constraints_for_aggregation, constraints)
    
    expected = {
      "name" => { "$in" => ["video", "audio"] }
    }
    
    assert_equal expected, result
  end
  
  def test_convert_constraints_for_aggregation_with_symbol_operators
    # Test that symbol operators (:$in, :$nin) work correctly
    pointer1 = Parse::Pointer.new("Team", "team1")
    pointer2 = Parse::Pointer.new("Team", "team2")
    
    constraints = {
      "_p_team" => { :$in => [pointer1, pointer2] }
    }
    
    result = @query.send(:convert_constraints_for_aggregation, constraints)
    
    expected = {
      "_p_team" => { :$in => ["Team$team1", "Team$team2"] }
    }
    
    assert_equal expected, result
  end
end