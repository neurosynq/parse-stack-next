require_relative "../../test_helper"

# Coverage for association-target validation:
#
#  * the definition-time scalar guard in `belongs_to` (which `property … as:`
#    delegates through), rejecting `as:` values that name a scalar data type
#    rather than a Parse class;
#  * the deferred `Parse.validate_associations!` pass, which flags pointer /
#    relation targets that do not resolve to a known Parse class once all
#    models are loaded.

# --- fixtures used by the deferred-pass tests -------------------------------
class AVTargetModel < Parse::Object
  parse_class "AVTargetModel"
end

class AVGoodRefs < Parse::Object
  parse_class "AVGoodRefs"
  belongs_to :rejected_by, as: :user            # -> _User (system class)
  belongs_to :target, class_name: "AVTargetModel" # -> loaded Ruby model
  property :reviewer, as: :user                 # delegated pointer -> _User
end

# has_many … through: :relation with a resolvable target feeds the `relations`
# branch of validate_associations!. (Fixtures with UNRESOLVABLE targets are
# defined inside their test methods as anonymous classes so they don't leak a
# permanently-broken edge into the global Parse::Object.descendants registry —
# which RelationGraph, schema introspection, and a future no-arg
# validate_associations! all walk.)
class AVRelationGood < Parse::Object
  parse_class "AVRelationGood"
  has_many :reviewers, through: :relation, as: :user # -> _User (resolves)
end

# A resolvable query-backed has_many feeds the `has_many_associations` branch.
# `as:` is singularized+camelized, so the target name must equal that form
# ("AvQueryTarget"), not the literal symbol. Defined at module scope (vs. an
# in-method anon class) so the permanently-resolvable fixture it adds to
# Parse::Object.descendants is intentional and named, matching AVRelationGood.
class AVQueryTarget < Parse::Object
  parse_class "AvQueryTarget"
end

class AVQueryGood < Parse::Object
  parse_class "AVQueryGood"
  has_many :things, as: :av_query_target # -> AvQueryTarget (resolves)
end

class AssociationValidationTest < Minitest::Test
  # --- definition-time scalar guard ----------------------------------------

  def test_property_as_scalar_type_raises
    err = assert_raises(ArgumentError) do
      Class.new(Parse::Object) do
        def self.parse_class(*) = "AVScalarProp"
        property :x, as: :string
      end
    end
    assert_match(/names the reserved data type :string/, err.message)
    assert_match(/property :x, :string/, err.message)
    assert_match(/class_name: "String"/, err.message)
  end

  def test_belongs_to_as_scalar_type_raises
    err = assert_raises(ArgumentError) do
      Class.new(Parse::Object) do
        def self.parse_class(*) = "AVScalarBT"
        belongs_to :y, as: :integer
      end
    end
    assert_match(/names the reserved data type :integer/, err.message)
  end

  def test_valid_pointer_declarations_do_not_raise
    klass = Class.new(Parse::Object) do
      def self.parse_class(*) = "AVValidPtr"
      property :rejected_by, as: :user
      belongs_to :owner, class_name: "AVTargetModel"
    end
    assert_equal :pointer, klass.fields[:rejected_by]
    assert_equal "_User", klass.references[:rejectedBy]
  end

  # A field whose default target (from the key name) collides with a scalar
  # word is NOT guarded — the guard only fires on an explicit `as:`, so
  # existing `belongs_to :something` declarations are never broken.
  def test_guard_only_fires_on_explicit_as
    klass = Class.new(Parse::Object) do
      def self.parse_class(*) = "AVImplicit"
      belongs_to :integer   # silly, but explicit-as guard must not fire
    end
    assert_equal :pointer, klass.fields[:integer]
  end

  # --- deferred validate_associations! -------------------------------------

  def test_validate_associations_passes_for_resolvable_targets
    assert_equal true,
                 Parse.validate_associations!(classes: [AVGoodRefs, AVTargetModel])
  end

  def test_validate_associations_flags_unresolved_target
    klass = Class.new(Parse::Object) do
      def self.parse_class(*) = "AVBadRef"
      belongs_to :thing, class_name: "AVTotallyMissing"
    end
    err = assert_raises(ArgumentError) do
      Parse.validate_associations!(classes: [klass])
    end
    assert_match(/Unresolved Parse association targets/, err.message)
    assert_match(/#thing -> "AVTotallyMissing"/, err.message)
  end

  def test_validate_associations_treats_system_classes_as_resolvable
    # _User is a system class with no app Ruby model required.
    assert_equal true, Parse.validate_associations!(classes: [AVGoodRefs])
  end

  # A typo'd system-class target (leading underscore) must NOT get a free pass.
  def test_validate_associations_flags_typod_system_class
    klass = Class.new(Parse::Object) do
      def self.parse_class(*) = "AVTypoSys"
      belongs_to :u, class_name: "_Usr" # misspelled _User
    end
    err = assert_raises(ArgumentError) do
      Parse.validate_associations!(classes: [klass])
    end
    assert_match(/"_Usr"/, err.message)
  end

  # The error names the declared accessor, not the camelCase remote column.
  def test_validate_associations_reports_declared_accessor
    klass = Class.new(Parse::Object) do
      def self.parse_class(*) = "AVAccessor"
      belongs_to :rejected_by, class_name: "AVTotallyMissing" # remote col rejectedBy
    end
    err = assert_raises(ArgumentError) do
      Parse.validate_associations!(classes: [klass])
    end
    assert_match(/#rejected_by ->/, err.message)
    refute_match(/rejectedBy/, err.message)
  end

  # --- has_many … through: :relation branch --------------------------------

  def test_validate_associations_passes_for_resolvable_relation
    assert_equal true, Parse.validate_associations!(classes: [AVRelationGood])
  end

  def test_validate_associations_flags_unresolved_relation
    klass = Class.new(Parse::Object) do
      def self.parse_class(*) = "AVRelationBad"
      has_many :widgets, through: :relation, as: :av_totally_missing # -> AvTotallyMissing
    end
    err = assert_raises(ArgumentError) do
      Parse.validate_associations!(classes: [klass])
    end
    assert_match(/#widgets \(relation\) -> "AvTotallyMissing"/, err.message)
  end

  # --- query- / array-backed has_many branch -------------------------------

  # A resolvable query-backed has_many (`as:` camelizes to a loaded model)
  # passes.
  def test_validate_associations_passes_for_resolvable_query_has_many
    assert_equal true,
                 Parse.validate_associations!(classes: [AVQueryGood, AVQueryTarget])
  end

  # The marquee gap this branch closes: a query-backed has_many with a typo'd
  # `as:` target sailed past the validator (it walks `references`/`relations`
  # only) and surfaced as a NameError when first traversed. It is now flagged.
  def test_validate_associations_flags_unresolved_query_has_many
    klass = Class.new(Parse::Object) do
      def self.parse_class(*) = "AVQueryBad"
      has_many :widgets, as: :av_totally_missing # -> AvTotallyMissing (query mode)
    end
    err = assert_raises(ArgumentError) do
      Parse.validate_associations!(classes: [klass])
    end
    assert_match(/#widgets \(has_many query\) -> "AvTotallyMissing"/, err.message)
  end

  # Array-backed has_many (`through: :array`) lives only in
  # `has_many_associations` too, so its target must be checked as well.
  def test_validate_associations_flags_unresolved_array_has_many
    klass = Class.new(Parse::Object) do
      def self.parse_class(*) = "AVArrayBad"
      has_many :widgets, through: :array, as: :av_totally_missing
    end
    err = assert_raises(ArgumentError) do
      Parse.validate_associations!(classes: [klass])
    end
    assert_match(/#widgets \(has_many array\) -> "AvTotallyMissing"/, err.message)
  end

  # A `:relation`-storage has_many is mirrored into `relations`; it must be
  # reported exactly once (as "(relation)"), not duplicated by the new branch.
  def test_validate_associations_does_not_double_report_relation_has_many
    klass = Class.new(Parse::Object) do
      def self.parse_class(*) = "AVRelationDup"
      has_many :widgets, through: :relation, as: :av_totally_missing
    end
    err = assert_raises(ArgumentError) do
      Parse.validate_associations!(classes: [klass])
    end
    assert_match(/#widgets \(relation\) -> "AvTotallyMissing"/, err.message)
    refute_match(/has_many relation/, err.message)
    assert_equal 1, err.message.scan(/#widgets/).length
  end

  # An unresolved belongs_to and an unresolved query has_many on the SAME class
  # must both be accumulated into one error — guards against a regression where
  # the has_many branch short-circuits instead of appending to `problems`.
  def test_validate_associations_aggregates_pointer_and_has_many_problems
    klass = Class.new(Parse::Object) do
      def self.parse_class(*) = "AVMixedBad"
      belongs_to :thing, class_name: "AVTotallyMissing"
      has_many :widgets, as: :av_also_missing
    end
    err = assert_raises(ArgumentError) do
      Parse.validate_associations!(classes: [klass])
    end
    assert_match(/#thing -> "AVTotallyMissing"/, err.message)
    assert_match(/#widgets \(has_many query\) -> "AvAlsoMissing"/, err.message)
  end

  # --- strict-redefinition on a scalar -> pointer redeclaration ------------

  def test_scalar_to_pointer_redeclaration_raises_under_strict
    # property :owner, :string then property :owner, as: :user used to silently
    # leave a :string column (belongs_to only warned). Under the default strict
    # mode it must now raise, mirroring property's own redefinition guard.
    err = assert_raises(ArgumentError) do
      Class.new(Parse::Object) do
        def self.parse_class(*) = "AVRedeclare"
        property :owner, :string
        property :owner, as: :user
      end
    end
    assert_match(/already defined as :string/, err.message)
    assert_match(/:pointer association/, err.message)
  end

  def test_scalar_to_pointer_redeclaration_warns_when_not_strict
    Parse.strict_property_redefinition = false
    klass = Class.new(Parse::Object) do
      def self.parse_class(*) = "AVRedeclareLoose"
      property :owner, :string
      property :owner, as: :user
    end
    # Non-strict: the redeclaration is ignored, field stays :string (the
    # belongs_to conflict path warns and returns false).
    assert_equal :string, klass.fields[:owner]
  ensure
    Parse.strict_property_redefinition = true
  end
end
