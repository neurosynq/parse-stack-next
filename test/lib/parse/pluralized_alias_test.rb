require_relative "../../test_helper"

# Coverage for the pluralized class-name alias convenience:
#
#  * automatic, lazy `const_missing` resolution (Posts -> Post) gated on
#    Parse.pluralized_aliases?;
#  * the explicit `pluralized_alias!` class macro (default + custom plural,
#    namespaced models, idempotency, clobber-protection);
#  * the design guards: classes whose name ends in `s` are skipped by the
#    automatic path, non-Parse plurals and typos fall through to NameError;
#  * the load-bearing invariant: an alias is the SAME class object, so it
#    never creates a new descendant and can never register a separate Parse
#    schema entry.

# --- fixtures ---------------------------------------------------------------
class PluPost < Parse::Object
  parse_class "PluPost"
  property :title, :string
end

class PluStatus < Parse::Object # name ends in "s" -> automatic path skips
  parse_class "PluStatus"
  property :name, :string
end

module PluBlog
  class Article < Parse::Object
    parse_class "PluBlogArticle"
    property :headline, :string
  end
end

class PluralizedAliasTest < Minitest::Test
  def setup
    @was_enabled = Parse.pluralized_aliases?
    Parse.pluralized_aliases = true
  end

  def teardown
    Parse.pluralized_aliases = @was_enabled
    # Clean up any constants the tests created so reruns start fresh. The
    # automatic path installs the alias on the *referencing* module — when a
    # test references a bare `PluPosts` inside this class body, that module is
    # the test class, not Object — so sweep both (plus the namespaced module).
    consts = %i[PluPosts PluStatuses PluGadgets PluPerson PluPeople PluReload PluReloads]
    [Object, self.class].each do |mod|
      consts.each { |c| mod.send(:remove_const, c) if mod.const_defined?(c, false) }
    end
    PluBlog.send(:remove_const, :Articles) if PluBlog.const_defined?(:Articles, false)
  end

  # --- automatic path -------------------------------------------------------

  def test_plural_reference_resolves_to_same_class
    assert PluPosts.equal?(PluPost), "Plural alias must be the same class object"
  end

  def test_alias_shares_parse_class_and_query_surface
    assert_equal "PluPost", PluPosts.parse_class
    q = PluPosts.where(:title => "hi")
    assert_instance_of Parse::Query, q
    assert_equal PluPost.query(:title => "hi").compile, q.compile
    assert PluPosts.respond_to?(:count)
    assert PluPosts.respond_to?(:find)
    assert PluPosts.respond_to?(:all)
  end

  def test_namespaced_model_aliases_within_its_module
    assert PluBlog::Articles.equal?(PluBlog::Article)
    # The alias is scoped to the module, not leaked to top level.
    refute Object.const_defined?(:Articles, false)
  end

  # --- guards ---------------------------------------------------------------

  def test_class_name_ending_in_s_is_skipped_by_automatic_path
    assert_raises(NameError) { PluStatuses }
  end

  def test_non_parse_plural_is_not_aliased
    # `Strings`.singularize == "String", which is not a Parse::Object.
    assert_raises(NameError) { Strings }
  end

  def test_typo_falls_through_to_name_error
    assert_raises(NameError) { PluTotallyMadeUpThings }
  end

  def test_opt_out_disables_automatic_aliasing
    Parse.pluralized_aliases = false
    assert_raises(NameError) { PluPosts }
  ensure
    Parse.pluralized_aliases = true
  end

  # --- explicit macro -------------------------------------------------------

  def test_macro_creates_default_plural
    assert_nil_or_const = PluPost.pluralized_alias!
    assert_equal PluPost, assert_nil_or_const
    assert PluPosts.equal?(PluPost)
  end

  def test_macro_is_idempotent
    PluPost.pluralized_alias!
    assert_equal PluPost, PluPost.pluralized_alias!
    assert PluPosts.equal?(PluPost)
  end

  def test_macro_allows_custom_plural_for_s_ending_class
    PluStatus.pluralized_alias!(:PluStatuses)
    assert PluStatuses.equal?(PluStatus)
  end

  def test_macro_raises_on_conflicting_existing_constant
    Object.const_set(:PluGadgets, Class.new) # name already occupied
    klass = Class.new(Parse::Object) do
      def self.name; "PluGadget"; end
    end
    assert_raises(ArgumentError) { klass.pluralized_alias!(:PluGadgets) }
  end

  def test_macro_on_namespaced_class_anchors_on_enclosing_module
    PluBlog::Article.pluralized_alias!
    assert PluBlog::Articles.equal?(PluBlog::Article)
    refute Object.const_defined?(:Articles, false)
  end

  def test_macro_supports_irregular_plural
    # const_set first so the class has a name (parse_class then defaults to it).
    Object.const_set(:PluPerson, Class.new(Parse::Object))
    PluPerson.pluralized_alias! # "Person".pluralize == "People"
    assert Object.const_defined?(:PluPeople, false)
    assert PluPeople.equal?(PluPerson)
  end

  def test_macro_is_reload_safe
    # Simulate a Zeitwerk dev-mode reload: the class object is swapped but the
    # alias constant we set is left pointing at the orphaned previous class.
    Object.const_set(:PluReload, Class.new(Parse::Object))
    PluReload.parse_class # memoize "PluReload" before the constant is swapped
    PluReload.pluralized_alias!
    old = PluReload
    assert PluReloads.equal?(old)

    Object.send(:remove_const, :PluReload)
    Object.const_set(:PluReload, Class.new(Parse::Object))
    PluReload.parse_class
    refute_equal old, PluReload

    # Re-running the macro must re-point the alias, not raise.
    assert_equal PluReload, PluReload.pluralized_alias!
    assert PluReloads.equal?(PluReload)
    refute PluReloads.equal?(old)
  end

  def test_macro_anchors_top_level_alias_not_under_parse_object
    PluPost.pluralized_alias!
    assert Object.const_defined?(:PluPosts, false)
    refute Parse::Object.const_defined?(:PluPosts, false),
           "alias must not be defined under Parse::Object"
  end

  # --- schema invariant -----------------------------------------------------

  def test_alias_never_adds_a_descendant_or_schema_class
    before = Parse::Object.descendants.count
    PluPost.pluralized_alias!
    PluPosts # force automatic path too (no-op, already defined)
    after = Parse::Object.descendants.count
    assert_equal before, after,
                 "Creating a plural alias must not add a Parse::Object descendant"
    # registered_classes is the schema-registration surface; the alias must
    # not appear as a separate parse_class.
    registered = Parse::Object.descendants.map(&:parse_class)
    assert_equal registered.count("PluPost"), 1,
                 "Aliased class must register exactly one schema class"
  end
end
