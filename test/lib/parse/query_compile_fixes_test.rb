# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Query compilation fixes: an OR with an unconstrained branch matches every
# row, the `:or` condition key builds a real `$or`, a repeated order field is
# sent once, and a bare objectId compared to a declared pointer column is
# sent to REST as a Pointer.
class QueryCompileFixesTest < Minitest::Test
  class FixArtist < Parse::Object
    parse_class "FixArtist"
    property :name, :string
  end

  class FixSong < Parse::Object
    parse_class "FixSong"
    property :plays, :integer
    property :title, :string
    property :state, :string
    property :tags, :array
    belongs_to :artist, as: :fix_artist
    belongs_to :owner, as: :user
    belongs_to :author_workspace, as: :fix_artist
  end

  # The compiled where with operator keys normalized to strings.
  def where_of(query)
    where = query.compile(encode: false)[:where]
    where && JSON.parse(where.to_json)
  end

  def pointer(class_name, id)
    { "__type" => "Pointer", "className" => class_name, "objectId" => id }
  end

  # OR with a match-all branch

  def test_pipe_with_empty_right_side_matches_all
    assert_nil where_of(FixSong.query(:plays => 2) | FixSong.query)
  end

  def test_pipe_with_empty_receiver_starts_the_or
    # An empty receiver is a seed, the same as or_where, so
    # `reduce(Model.query, :|)` builds the OR of the members.
    assert_equal({ "$or" => [{ "plays" => 2 }] }, where_of(FixSong.query | FixSong.query(:plays => 2)))
  end

  def test_pipe_reduce_from_empty_seed_builds_the_or
    q = [FixSong.query(:plays => 1), FixSong.query(:plays => 2)].reduce(FixSong.query, :|)
    assert_equal({ "$or" => [{ "plays" => 1 }, { "plays" => 2 }] }, where_of(q))
  end

  def test_pipe_with_both_sides_empty_matches_all
    assert_nil where_of(FixSong.query | FixSong.query)
  end

  def test_query_or_with_empty_member_matches_all
    assert_nil where_of(Parse::Query.or(FixSong.query(:plays => 1), FixSong.query))
  end

  def test_query_or_without_empty_member_is_unchanged
    assert_equal({ "$or" => [{ "plays" => 1 }, { "plays" => 2 }] },
                 where_of(Parse::Query.or(FixSong.query(:plays => 1), FixSong.query(:plays => 2))))
  end

  def test_or_where_with_empty_query_matches_all
    assert_nil where_of(FixSong.query(:plays => 1).or_where(FixSong.query))
  end

  def test_or_where_builder_on_empty_receiver_still_starts_the_or
    q = FixSong.query.or_where(:plays => 1).or_where(:plays => 2)
    assert_equal({ "$or" => [{ "plays" => 1 }, { "plays" => 2 }] }, where_of(q))
  end

  def test_pipe_keeps_receiver_options_when_collapsing
    q = FixSong.query(:plays => 1).limit(5).order(:title) | FixSong.query
    compiled = q.compile(encode: false)
    assert_equal 5, compiled[:limit]
    assert_equal "title", compiled[:order]
    assert_nil compiled[:where]
  end

  # OR branches with pipeline-only constraints are refused

  def test_or_key_refuses_marker_only_branch
    err = assert_raises(ArgumentError) { FixSong.query(:or => [{ readable_by: "u1" }, { :title => "x" }]) }
    assert_match(/not supported inside an OR/, err.message)
  end

  def test_or_key_refuses_array_size_branch_instead_of_emitting_empty_branch
    q = nil
    err = assert_raises(ArgumentError) { q = FixSong.query(:or => [{ :tags.array_size => 2 }, { state: "active" }]) }
    assert_match(/not supported inside an OR/, err.message)
    assert_nil q
  end

  def test_or_key_refuses_acl_readable_by_branch
    assert_raises(ArgumentError) { FixSong.query(:or => [{ :ACL.readable_by => "u1" }, { :title => "x" }]) }
  end

  def test_or_key_refuses_mixed_marker_branch
    assert_raises(ArgumentError) { FixSong.query(:or => [{ :title => "x", :tags.array_size => 2 }, { :plays => 1 }]) }
  end

  def test_or_key_refuses_marker_branch_even_beside_a_match_all_branch
    assert_raises(ArgumentError) { FixSong.query(:or => [{ :tags.array_size => 2 }, {}]) }
  end

  def test_pipe_refuses_marker_right_side
    assert_raises(ArgumentError) { FixSong.query(:title => "x") | FixSong.query(:tags.array_size => 2) }
  end

  def test_pipe_refuses_marker_receiver
    assert_raises(ArgumentError) { FixSong.query(:tags.array_size => 2) | FixSong.query(:title => "x") }
    assert_raises(ArgumentError) { FixSong.query(:tags.array_size => 2) | FixSong.query }
  end

  def test_or_where_refuses_marker_constraints
    assert_raises(ArgumentError) { FixSong.query(:title => "x").or_where(:tags.array_size => 2) }
    assert_raises(ArgumentError) { FixSong.query(readable_by: "u1").or_where(:title => "x") }
  end

  def test_query_or_refuses_marker_member
    assert_raises(ArgumentError) { Parse::Query.or(FixSong.query(:title => "x"), FixSong.query(:tags.array_size => 2)) }
    # Refused even when another member would make the OR match-all.
    assert_raises(ArgumentError) { Parse::Query.or(FixSong.query, FixSong.query(:tags.array_size => 2)) }
  end

  def test_marker_constraints_outside_an_or_still_work
    q = FixSong.query(:tags.array_size => 2, :or => [{ :plays => 1 }, { :plays => 2 }])
    assert q.requires_aggregation_pipeline?
    assert_equal({ "$or" => [{ "plays" => 1 }, { "plays" => 2 }] }, where_of(q))
  end

  def test_push_where_refuses_marker_or_branch
    push = Parse::Push.new
    assert_raises(ArgumentError) do
      push.where(:or => [{ :ACL.readable_by => "u1" }, { :device_type => "android" }])
    end
  end

  # :or Array branches

  def test_or_array_branch_expands_hash_elements
    q = FixSong.query(:or => [[Parse::Constraint.create(:title, "a")], [{ :title => "b" }]])
    assert_equal({ "$or" => [{ "title" => "a" }, { "title" => "b" }] }, where_of(q))
  end

  def test_or_array_branch_rejects_other_elements
    assert_raises(ArgumentError) { FixSong.query(:or => [[Parse::Constraint.create(:title, "a")], ["title"]]) }
  end

  def test_or_key_rejects_query_branch_of_another_class
    assert_raises(ArgumentError) { FixSong.query(:or => [FixArtist.query(:name => "x"), { :plays => 1 }]) }
  end

  # Auth scope survives clone, | and Parse::Query.or

  def test_clone_keeps_auth_scope
    q = FixSong.query(:plays => 1)
    q.session_token = "r:abc"
    q.read_preference = :secondary
    copy = q.clone
    assert_equal "r:abc", copy.session_token
    assert_equal :secondary, copy.read_preference
  end

  def test_pipe_keeps_receiver_session_when_collapsing
    q = FixSong.query(:plays => 1)
    q.session_token = "r:abc"
    combined = q | FixSong.query
    assert_equal "r:abc", combined.session_token
    assert_nil where_of(combined)
  end

  def test_pipe_adopts_right_side_session
    other = FixSong.query(:plays => 2)
    other.session_token = "r:abc"
    combined = FixSong.query(:plays => 1) | other
    assert_equal "r:abc", combined.session_token
  end

  def test_pipe_refuses_different_sessions
    a = FixSong.query(:plays => 1)
    a.session_token = "r:a"
    b = FixSong.query(:plays => 2)
    b.session_token = "r:b"
    assert_raises(ArgumentError) { a | b }
  end

  def test_query_or_carries_common_scope
    a = FixSong.query(:plays => 1)
    a.session_token = "r:abc"
    b = FixSong.query(:plays => 2)
    b.session_token = "r:abc"
    assert_equal "r:abc", Parse::Query.or(a, b).session_token
    assert_equal "r:abc", Parse::Query.or(a, FixSong.query).session_token
  end

  def test_query_or_refuses_different_scopes
    a = FixSong.query(:plays => 1)
    a.session_token = "r:a"
    b = FixSong.query(:plays => 2)
    b.use_master_key = false
    b.session_token = "r:b"
    assert_raises(ArgumentError) { Parse::Query.or(a, b) }
  end

  def test_query_or_refuses_different_scoped_users
    u1 = Parse::User.new(objectId: "u1")
    u2 = Parse::User.new(objectId: "u2")
    a = FixSong.query(:plays => 1).scope_to_user(u1)
    b = FixSong.query(:plays => 2).scope_to_user(u2)
    assert_raises(ArgumentError) { Parse::Query.or(a, b) }
    same = FixSong.query(:plays => 3).scope_to_user(Parse::User.new(objectId: "u1"))
    assert_equal "u1", Parse::Query.or(a, same).acl_user.id
  end

  # Effective authority: different kinds of scope never merge

  def alice_query(plays = 1)
    q = FixSong.query(:plays => plays)
    q.session_token = "r:alice"
    q
  end

  def bob_query(plays = 2)
    FixSong.query(:plays => plays).scope_to_user(Parse::User.new(objectId: "bob"))
  end

  def test_session_and_scoped_user_refused_for_pipe
    err = assert_raises(ArgumentError) { alice_query | bob_query }
    assert_match(/same authority/, err.message)
    refute_match(/r:alice/, err.message, "the session token must not appear in the error")
    assert_raises(ArgumentError) { bob_query | alice_query }
  end

  def test_session_and_scoped_user_refused_for_or_where
    assert_raises(ArgumentError) { alice_query.or_where(bob_query) }
    assert_raises(ArgumentError) { bob_query.or_where(alice_query) }
  end

  def test_session_and_scoped_user_refused_for_query_or
    assert_raises(ArgumentError) { Parse::Query.or(alice_query, bob_query) }
    assert_raises(ArgumentError) { Parse::Query.or(bob_query, FixSong.query(:plays => 3), alice_query) }
  end

  def test_session_and_master_refused
    master = FixSong.query(:plays => 2)
    master.use_master_key = true
    assert_raises(ArgumentError) { alice_query | master }
    assert_raises(ArgumentError) { Parse::Query.or(master, alice_query) }
  end

  def test_scoped_user_and_scoped_role_refused
    role = FixSong.query(:plays => 3).scope_to_role("admin")
    assert_raises(ArgumentError) { bob_query | role }
  end

  def test_explicit_no_master_beside_session_is_the_same_authority
    b = alice_query(2)
    b.use_master_key = false
    assert_equal "r:alice", (alice_query | b).session_token
  end

  def test_explicit_no_master_and_session_refused
    public_only = FixSong.query(:plays => 2)
    public_only.use_master_key = false
    assert_raises(ArgumentError) { public_only | alice_query }
  end

  # :or Parse::Query branches carry their authority

  def test_or_key_query_branch_adopts_session
    q = Parse::Query.new("FixSong", :or => [alice_query, { plays: 5 }])
    assert_equal "r:alice", q.session_token
    assert_equal "r:alice", q.send(:_opts)[:session_token]
  end

  def test_or_key_query_branches_with_different_authority_refused
    assert_raises(ArgumentError) { Parse::Query.new("FixSong", :or => [alice_query, bob_query]) }
  end

  def test_or_key_query_branch_conflicts_with_receiver_session
    assert_raises(ArgumentError) do
      Parse::Query.new("FixSong", :session => "r:other", :or => [alice_query])
    end
    # Order of keys in the Hash does not matter.
    assert_raises(ArgumentError) do
      Parse::Query.new("FixSong", :or => [alice_query], :session => "r:other")
    end
  end

  def test_or_key_query_branch_conflicts_with_receiver_master
    assert_raises(ArgumentError) do
      Parse::Query.new("FixSong", :use_master_key => true, :or => [alice_query])
    end
  end

  def test_or_key_query_branch_never_runs_as_master
    q = Parse::Query.new("FixSong", :or => [alice_query])
    opts = q.send(:_opts)
    refute_equal true, opts[:use_master_key]
    assert_equal "r:alice", opts[:session_token]
  end

  # The adopted authority is pinned

  def test_changing_session_after_combining_raises
    combined = FixSong.query(:plays => 1) | alice_query
    assert_raises(ArgumentError) { combined.session_token = "r:mallory" }
    assert_raises(ArgumentError) { combined.session_token = nil }
    assert_raises(ArgumentError) { combined.use_master_key = true }
    assert_raises(ArgumentError) { combined.scope_to_user(Parse::User.new(objectId: "bob")) }
  end

  def test_changing_authority_on_or_key_query_raises
    q = Parse::Query.new("FixSong", :or => [alice_query])
    assert_raises(ArgumentError) { q.use_master_key = true }
    assert_raises(ArgumentError) { q.clone.session_token = "r:bob" }
  end

  def test_setting_same_authority_after_combining_is_fine
    combined = FixSong.query(:plays => 1) | alice_query
    combined.session_token = "r:alice"
    combined.use_master_key = false
    assert_equal "r:alice", combined.session_token
  end

  def test_unscoped_combination_leaves_authority_free
    combined = FixSong.query(:plays => 1) | FixSong.query(:plays => 2)
    combined.session_token = "r:anyone"
    assert_equal "r:anyone", combined.session_token
  end

  # A rejected authority change leaves the query untouched

  def assert_still_alice(q)
    assert_equal "r:alice", q.session_token
    assert_nil q.use_master_key
    assert_nil q.acl_user
    assert_nil q.acl_role
    opts = q.send(:_opts)
    assert_equal "r:alice", opts[:session_token]
    refute_equal true, opts[:use_master_key]
    assert_equal({ session_token: "r:alice" }, q.send(:mongo_direct_scope_kwargs))
  end

  def test_rejected_session_change_restores_state
    combined = FixSong.query(:plays => 1) | alice_query
    assert_raises(ArgumentError) { combined.session_token = nil }
    assert_still_alice(combined)
    assert_raises(ArgumentError) { combined.session_token = "r:mallory" }
    assert_still_alice(combined)
  end

  def test_rejected_master_change_restores_state
    combined = FixSong.query(:plays => 1) | alice_query
    assert_raises(ArgumentError) { combined.use_master_key = true }
    assert_still_alice(combined)
  end

  def test_rejected_scope_to_user_restores_state
    combined = FixSong.query(:plays => 1) | alice_query
    assert_raises(ArgumentError) { combined.scope_to_user(Parse::User.new(objectId: "bob")) }
    assert_still_alice(combined)
  end

  def test_rejected_scope_to_role_restores_state
    combined = FixSong.query(:plays => 1) | alice_query
    assert_raises(ArgumentError) { combined.scope_to_role("admin") }
    assert_still_alice(combined)
  end

  def test_rejected_client_change_restores_state
    alice_client = default_client.become("r:alice")
    branch = FixSong.query(:plays => 1)
    branch.client = alice_client
    combined = FixSong.query(:plays => 2) | branch
    assert_raises(ArgumentError) { combined.client = default_client.become("r:bob") }
    assert_same alice_client, combined.client
    assert_raises(ArgumentError) { combined.client = default_client }
    assert_same alice_client, combined.client
    assert_equal({ session_token: "r:alice" }, combined.send(:mongo_direct_scope_kwargs))
  end

  # The scoped side pins the result whichever operand order is used.

  def test_scoped_receiver_pins_authority_with_unscoped_right_side
    combined = alice_query | FixSong.query(:plays => 2)
    assert_raises(ArgumentError) { combined.session_token = nil }
    assert_still_alice(combined)
    assert_raises(ArgumentError) { combined.use_master_key = true }
    assert_still_alice(combined)
  end

  def test_scoped_receiver_pins_authority_with_match_all_right_side
    combined = alice_query | FixSong.query
    assert_raises(ArgumentError) { combined.session_token = nil }
    assert_equal "r:alice", combined.session_token
  end

  def test_scoped_receiver_pins_authority_through_or_where
    combined = alice_query.or_where(FixSong.query(:plays => 2))
    assert_raises(ArgumentError) { combined.session_token = nil }
    assert_still_alice(combined)
  end

  def test_scoped_first_member_pins_authority_in_query_or
    combined = Parse::Query.or(alice_query, FixSong.query(:plays => 2))
    assert_raises(ArgumentError) { combined.session_token = nil }
    assert_still_alice(combined)
  end

  def test_scoped_receiver_pins_authority_with_unscoped_or_key_branch
    receiver = alice_query
    receiver.conditions(:or => [FixSong.query(:plays => 2)])
    assert_raises(ArgumentError) { receiver.session_token = nil }
    assert_still_alice(receiver)
  end

  def test_execution_refuses_a_changed_pinned_authority
    combined = FixSong.query(:plays => 1) | alice_query
    combined.instance_variable_set(:@session_token, nil)
    assert_raises(ArgumentError) { combined.send(:_opts) }
    assert_raises(ArgumentError) { combined.send(:mongo_direct_scope_kwargs) }
    assert_raises(ArgumentError) { combined.send(:atlas_search_scope_kwargs) }
  end

  # A session-bound client is part of the query's authority

  def default_client
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1/parse", application_id: "a",
                  api_key: "k", master_key: "mk")
    end
    Parse::Client.client
  end

  def become_query(token = "r:alice", plays = 1)
    q = FixSong.query(:plays => plays)
    q.client = default_client.become(token)
    q
  end

  def assert_runs_as_alice(q)
    refute_equal true, q.send(:_opts)[:use_master_key]
    # REST sends the explicit token, or else the client's bound one.
    assert_equal "r:alice", q.session_token || q.client.session_token
    assert_equal({ session_token: "r:alice" }, q.send(:mongo_direct_scope_kwargs))
  end

  def test_become_query_in_or_key_runs_as_its_session
    default_client
    q = Parse::Query.new("FixSong", :or => [become_query, { plays: 5 }])
    assert_runs_as_alice(q)
  end

  def test_become_query_in_pipe_runs_as_its_session
    default_client
    assert_runs_as_alice(FixSong.query(:plays => 2) | become_query)
    assert_runs_as_alice(become_query | FixSong.query(:plays => 2))
  end

  def test_become_query_in_query_or_runs_as_its_session
    default_client
    assert_runs_as_alice(Parse::Query.or(FixSong.query(:plays => 2), become_query))
  end

  def test_clone_keeps_become_client
    default_client
    q = become_query
    assert_same q.client, q.clone.client
    assert_runs_as_alice(q.clone)
  end

  def test_become_query_matches_explicit_session
    default_client
    combined = alice_query | become_query
    assert_runs_as_alice(combined)
  end

  def test_conflicting_become_clients_raise
    default_client
    assert_raises(ArgumentError) { become_query("r:alice") | become_query("r:bob", 2) }
    assert_raises(ArgumentError) { Parse::Query.new("FixSong", :or => [become_query("r:alice"), become_query("r:bob", 2)]) }
    assert_raises(ArgumentError) { become_query("r:alice") | bob_query }
  end

  def test_anonymous_client_query_never_runs_as_master
    default_client
    anon = FixSong.query(:plays => 1)
    anon.client = default_client.anonymous
    combined = FixSong.query(:plays => 2) | anon
    refute_equal true, combined.send(:_opts)[:use_master_key]
    assert_equal({}, combined.send(:mongo_direct_scope_kwargs))
    assert_raises(ArgumentError) { anon | alice_query }
  end

  def test_receiver_with_own_master_client_takes_the_session
    default_client
    other_master = Parse::Client.new(server_url: "http://localhost:1/parse", app_id: "a",
                                     api_key: "k", master_key: "mk")
    receiver = FixSong.query(:plays => 2)
    receiver.client = other_master
    receiver.or_where(become_query)
    assert_same other_master, receiver.client
    assert_equal "r:alice", receiver.session_token
    assert_equal "r:alice", receiver.send(:_opts)[:session_token]
    assert_runs_as_alice(receiver)
  end

  # :or condition key

  def test_or_key_builds_or_anded_with_siblings
    q = FixSong.query(:title => "t", :or => [{ :plays => 1 }, { :plays.gt => 9 }])
    assert_equal({ "title" => "t", "$or" => [{ "plays" => 1 }, { "plays" => { "$gt" => 9 } }] }, where_of(q))
  end

  def test_or_key_accepts_query_branches
    q = FixSong.query(:or => [FixSong.query(:plays => 1), FixSong.query(:title => "a")])
    assert_equal({ "$or" => [{ "plays" => 1 }, { "title" => "a" }] }, where_of(q))
  end

  def test_or_key_with_match_all_branch_adds_nothing
    assert_equal({ "title" => "t" }, where_of(FixSong.query(:title => "t", :or => [{ :plays => 1 }, {}])))
  end

  def test_or_key_with_empty_list_matches_no_rows
    assert_equal({ "title" => "t", "objectId" => { "$in" => [] } },
                 where_of(FixSong.query(:title => "t", :or => [])))
  end

  def test_or_key_rejects_non_array
    assert_raises(ArgumentError) { FixSong.query(:or => { :plays => 1 }) }
  end

  def test_string_or_key_stays_a_field_name
    assert_equal({ "or" => 5 }, where_of(FixSong.query("or" => 5)))
  end

  def test_or_key_combines_with_or_where
    q = FixSong.query(:or => [{ :plays => 1 }, { :plays => 2 }]).where(:title => "t")
    assert_equal({ "$or" => [{ "plays" => 1 }, { "plays" => 2 }], "title" => "t" }, where_of(q))
  end

  # Repeated order field

  def test_repeated_order_field_is_sent_once
    q = FixSong.query.order(:title, :plays.desc, :title.desc)
    assert_equal "-title,-plays", q.compile(encode: false)[:order]
  end

  def test_repeated_order_across_calls_and_hash_form
    q = FixSong.query.order(:plays).order({ :title => :asc }).order(:plays.desc)
    assert_equal "-plays,title", q.compile(encode: false)[:order]
  end

  def test_repeated_order_matches_direct_sort_stage
    q = FixSong.query.order(:title, :plays.desc, :title.desc)
    assert_equal({ "$sort" => { "title" => -1, "plays" => -1 } }, q.send(:query_sort_stage))
  end

  def test_string_prefixed_order_field_is_deduplicated
    assert_equal "title", FixSong.query.order("-title", :title).compile(encode: false)[:order]
    assert_equal "-plays,title", FixSong.query.order("-plays", "+title").compile(encode: false)[:order]
  end

  def test_string_prefixed_order_gives_direct_sort_a_real_field
    q = FixSong.query.order("-title")
    assert_equal({ "$sort" => { "title" => -1 } }, q.send(:query_sort_stage))
  end

  # Bare objectId on a declared pointer (REST)

  def test_bare_id_equality_on_pointer_becomes_pointer
    assert_equal({ "artist" => pointer("FixArtist", "abc123") }, where_of(FixSong.query(:artist => "abc123")))
  end

  def test_bare_id_operators_on_pointer_become_pointers
    q = FixSong.query(:owner.ne => "u1", :author_workspace.in => ["w1", "w2"])
    assert_equal({ "owner" => { "$ne" => pointer("_User", "u1") },
                   "authorWorkspace" => { "$in" => [pointer("FixArtist", "w1"), pointer("FixArtist", "w2")] } },
                 where_of(q))
  end

  def test_bare_id_inside_or_branch_is_coerced
    q = FixSong.query(:plays => 1) | FixSong.query(:artist => "abc123")
    assert_equal({ "$or" => [{ "plays" => 1 }, { "artist" => pointer("FixArtist", "abc123") }] }, where_of(q))
  end

  def test_coercion_survives_json_encoding
    where = JSON.parse(FixSong.query(:artist => "abc123").compile[:where])
    assert_equal({ "artist" => pointer("FixArtist", "abc123") }, where)
  end

  def test_non_pointer_and_storage_form_values_are_left_alone
    q = FixSong.query(:title => "abc123", :artist => "FixArtist$abc", "artist.name" => "x")
    assert_equal({ "title" => "abc123", "artist" => "FixArtist$abc", "artist.name" => "x" }, where_of(q))
  end

  def test_pointer_values_are_left_alone
    q = FixSong.query(:artist => FixArtist.pointer("abc123"))
    assert_equal({ "artist" => pointer("FixArtist", "abc123") }, JSON.parse(q.compile[:where]))
  end

  def test_undeclared_table_is_left_alone
    q = Parse::Query.new("NoSuchModelForFixes", :artist => "abc123")
    assert_equal({ "artist" => "abc123" }, where_of(q))
  end

  def test_compile_where_keeps_raw_form_for_direct_paths
    # Direct and aggregate paths convert to the "Class$id" storage form
    # themselves, so compile_where is not rewritten.
    assert_equal({ "artist" => "abc123" }, JSON.parse(FixSong.query(:artist => "abc123").compile_where.to_json))
  end

  # LiveQuery subscribe and push targeting send the where clause to Parse
  # Server too, so they get the same pointer coercion as REST.

  def test_compile_rest_where_coerces_bare_pointer_ids
    where = JSON.parse(FixSong.query(:artist => "abc123", :plays => 2).compile_rest_where.to_json)
    assert_equal pointer("FixArtist", "abc123"), where["artist"]
    assert_equal 2, where["plays"]
  end

  def test_live_query_subscribe_coerces_bare_pointer_ids
    require_relative "../../../lib/parse/live_query"
    client = Parse::LiveQuery::Client.new(
      url: "wss://test.example.com",
      application_id: "test_app_id",
      client_key: "test_key",
      auto_connect: false,
    )
    subscription = client.subscribe(FixSong.query(:artist.in => ["abc123"]))
    where = JSON.parse(subscription.query.to_json)
    assert_equal({ "$in" => [pointer("FixArtist", "abc123")] }, where["artist"])
  ensure
    Parse::LiveQuery.reset! if defined?(Parse::LiveQuery) && Parse::LiveQuery.respond_to?(:reset!)
  end

  def test_query_subscribe_coerces_bare_pointer_ids
    require_relative "../../../lib/parse/live_query"
    client = Parse::LiveQuery::Client.new(
      url: "wss://test.example.com", application_id: "test_app_id", client_key: "test_key", auto_connect: false,
    )
    sub = FixSong.query(:artist => "abc123").subscribe(client: client)
    assert_equal pointer("FixArtist", "abc123"), JSON.parse(sub.query.to_json)["artist"]
    sub2 = FixSong.subscribe(where: { :artist => "abc123" }, client: client)
    assert_equal pointer("FixArtist", "abc123"), JSON.parse(sub2.query.to_json)["artist"]
  ensure
    Parse::LiveQuery.reset! if defined?(Parse::LiveQuery) && Parse::LiveQuery.respond_to?(:reset!)
  end

  def test_push_where_coerces_bare_pointer_ids
    push = Parse::Push.new
    push.where(:user => "abc123")
    where = JSON.parse(push.payload[:where].to_json)
    assert_equal pointer("_User", "abc123"), where["user"]
  end

end
