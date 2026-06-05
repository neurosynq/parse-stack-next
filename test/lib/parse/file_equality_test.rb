# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "minitest/autorun"

# Locks in Parse::File equality semantics, which drive :file-property dirty
# tracking: the property setter compares the incoming and current file with
# `==` to decide whether a :file field changed. Equality routes through
# #content_signature (default: the bare canonical #url), so it is symmetric and
# force_ssl-consistent. The previous `@url == u.url` form compared one side's
# raw stored URL against the other's normalized reader, which read as unequal
# under force_ssl and could spuriously mark a file property changed.
class FileEqualityTest < Minitest::Test
  def setup
    @force_ssl_was = Parse::File.force_ssl
    @trusted_was = Parse::File.trusted_url_hosts
    # files.parsetfss.com is a default-trusted host; pin it so building from a
    # hash never warns or attempts host resolution.
    Parse::File.trusted_url_hosts = ["files.parsetfss.com"]
  end

  def teardown
    Parse::File.force_ssl = @force_ssl_was
    Parse::File.trusted_url_hosts = @trusted_was
  end

  # Build via the JSON hash form (no DNS/host check, unlike the string form).
  def file(url)
    Parse::File.new({ "__type" => "File", "name" => "f", "url" => url })
  end

  def test_same_location_equal
    assert_equal file("https://files.parsetfss.com/a.png"),
                 file("https://files.parsetfss.com/a.png")
  end

  def test_different_location_not_equal
    refute_equal file("https://files.parsetfss.com/a.png"),
                 file("https://files.parsetfss.com/b.png")
  end

  # The fix: with force_ssl on, an http and an https URL for the SAME location
  # are equal AND the relation is symmetric. The old `@url == u.url` form
  # compared one side's raw http against the other's coerced https => false.
  def test_force_ssl_consistent_and_symmetric
    Parse::File.force_ssl = true
    a = file("http://files.parsetfss.com/a.png")
    b = file("http://files.parsetfss.com/a.png")
    assert a == b, "two same-location files must be equal under force_ssl"
    assert b == a, "equality must be symmetric under force_ssl"

    c = file("http://files.parsetfss.com/a.png")
    d = file("https://files.parsetfss.com/a.png")
    assert c == d, "http and https for the same location are equal under force_ssl"
    assert d == c, "and symmetric"
  end

  def test_nil_url_files_equal
    assert_equal file(nil), file(nil),
                 "two files with no url (not yet uploaded) compare equal"
  end

  def test_non_file_comparand_is_not_equal
    f = file("https://files.parsetfss.com/a.png")
    refute f == "https://files.parsetfss.com/a.png",
           "a File must not equal a bare String"
    refute f == nil, "a File must not equal nil"
  end

  # content_signature is the documented override seam for future content-hash
  # equality (e.g. an S3 ETag / sha256); overriding it changes == without
  # touching dirty tracking. Default behavior keys off url.
  def test_content_signature_default_is_url
    f = file("https://files.parsetfss.com/a.png")
    assert_equal f.url, f.content_signature
  end

  def test_content_signature_override_keys_off_content
    klass = Class.new(Parse::File) do
      attr_accessor :etag
      def content_signature
        etag || super
      end
    end
    a = klass.new({ "__type" => "File", "name" => "f", "url" => "https://files.parsetfss.com/v1.png" })
    a.etag = "E1"
    b = klass.new({ "__type" => "File", "name" => "f", "url" => "https://files.parsetfss.com/v2.png" })
    b.etag = "E1"
    assert a == b, "an override makes same-content files at different urls equal"
  end

  # The reason the == fix matters: a :file property must NOT report changed when
  # the same-location file is re-assigned under force_ssl. Before the fix this
  # spuriously marked the property dirty (raw-http vs coerced-https compare).
  class FileEqPost < Parse::Object
    parse_class "FileEqPost"
    property :avatar, :file
  end

  def test_file_property_dirty_tracking_is_force_ssl_consistent
    Parse::File.force_ssl = true
    post = FileEqPost.new(avatar: file("http://files.parsetfss.com/a.png"))
    post.clear_changes!

    post.avatar = file("http://files.parsetfss.com/a.png") # same location
    refute post.avatar_changed?,
           "re-assigning the same-location file must not mark the property changed under force_ssl"

    post.avatar = file("http://files.parsetfss.com/b.png") # different location
    assert post.avatar_changed?,
           "assigning a different-location file marks the property changed"
  end
end
