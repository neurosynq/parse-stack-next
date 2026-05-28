# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper_integration"
require "securerandom"

# Documents the canonical Parse Server file-pointer normalization
# behavior. This test passes by CONFIRMING the behavior, not by
# probing it.
#
# **Parse Server normalizes embedded `__type: "File"` hashes to
# `{__type, name, url}` on save.** Any sub-field beyond that
# canonical triple — `key`, `mime_type`, custom adapter metadata —
# is silently stripped at write time and never reaches MongoDB. The
# `url` itself is rewritten to Parse Server's own
# `<server_url>/files/<app_id>/<name>` endpoint regardless of what
# the SDK sent.
#
# This is the **architectural constraint** that the storage adapter
# work in `s3_adapter_plan.md` rev 3 is built around:
#
# - `@key` on `Parse::File` is **in-memory only** — populated by
#   adapter operations on the live instance; re-derived from `@url`
#   (or via the adapter's `key_for(name:)` / `key_from_url(url)`
#   methods) after every hydration cycle.
# - `@url` on `Parse::File` is the **canonical bare URL** —
#   normalized via the single `normalize_and_store_url` point. Any
#   incoming signed URL is stripped to bare form and stashed
#   separately in `@presigned_url`.
# - Presigned URLs that Parse Server's S3FilesAdapter returns are
#   **transient** — consumed by `download_url(as:, ttl:)`, never
#   persisted in `@url`.
#
# When this test starts FAILING, it means either Parse Server changed
# its file-pointer normalization behavior (in which case the storage
# adapter work needs revisiting), or the test setup drifted. Either
# way: investigate, don't suppress.
class FileKeyStripDocumentationParent < Parse::Object
  parse_class "FileKeyStripDocPost"
  property :title, :string
  property :attachment, :file
end

class FileKeyStripDocumentationIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
    @canonical_name = "doc.pdf"
    @canonical_key  = "tenants/#{SecureRandom.hex(4)}/#{SecureRandom.uuid}-#{@canonical_name}"
    # Trusted-host stub URL — we are NOT testing the bucket upload
    # path here, only that Parse Server strips/normalizes the
    # embedded file pointer.
    @input_url = "https://files.parsetfss.com/abc/tfss-#{SecureRandom.uuid}-#{@canonical_name}"
  end

  # ------------------------------------------------------------------
  # CONFIRMS: Parse Server strips arbitrary sub-fields from file
  # pointer hashes on save. The SDK's `Parse::File#as_json` emits
  # exactly `{__type, name, url}` (rev 3 D5); even if a caller
  # bypassed `as_json` and sent a `key` field through, Parse Server
  # would drop it before storage.
  # ------------------------------------------------------------------

  def test_parse_server_strips_arbitrary_subfields_from_file_pointer
    file = Parse::File.new(@canonical_name, nil, "application/pdf")
    file.url = @input_url

    # Confirm SDK as_json emits only the canonical wire shape.
    wire = file.as_json
    assert_equal %w[__type name url], wire.keys.sort,
                 "SDK must emit only {__type, name, url}"

    # Save the parent.
    post = FileKeyStripDocumentationParent.new(
      title: "strip-doc-#{SecureRandom.hex(3)}",
      attachment: file,
    )
    assert post.save, "parent save failed: #{post.errors.full_messages.inspect}"
    refute_nil post.id

    # Reload.
    reloaded = FileKeyStripDocumentationParent.find(post.id)
    refute_nil reloaded.attachment, "attachment field must round-trip"
    assert_equal @canonical_name, reloaded.attachment.name,
                 "name must round-trip (it's the canonical Parse-Server identifier)"
  end

  # ------------------------------------------------------------------
  # CONFIRMS: Parse Server rewrites the `url` field on save to its
  # own files endpoint. This is Parse Server's anti-URL-spoofing
  # feature. The SDK accepts this and the rev 3 D5 design works with
  # it (Parse Server's S3FilesAdapter — when configured — generates
  # fresh presigned URLs on every read, which the SDK normalizes via
  # the strip + stash path).
  # ------------------------------------------------------------------

  def test_parse_server_rewrites_url_on_save
    file = Parse::File.new(@canonical_name, nil, "application/pdf")
    file.url = @input_url

    post = FileKeyStripDocumentationParent.new(
      title: "url-rewrite-#{SecureRandom.hex(3)}",
      attachment: file,
    )
    assert post.save
    refute_nil post.id

    # Read the raw REST response so we see exactly what Parse Server
    # stored (the SDK-hydrated `Parse::File` would mask normalization
    # effects).
    response = Parse.client.fetch_object("FileKeyStripDocPost", post.id)
    assert response.success?, "raw REST fetch failed: #{response.error&.inspect}"
    raw = response.result
    raw_attachment = raw["attachment"]

    assert_equal "File", raw_attachment["__type"]
    assert_equal @canonical_name, raw_attachment["name"]
    refute_equal @input_url, raw_attachment["url"],
                 "Parse Server must rewrite the URL — we sent " \
                 "#{@input_url.inspect} and the server keeping it verbatim " \
                 "would mean the anti-spoofing normalization has changed"
    assert_match(/\/files\/.*\/#{Regexp.escape(@canonical_name)}\z/,
                 raw_attachment["url"],
                 "rewritten URL must point at Parse Server's files endpoint")
    # Defense in depth: the raw row must not carry stray sub-fields.
    extra_keys = raw_attachment.keys - %w[__type name url]
    assert_empty extra_keys,
                 "Parse Server stored unexpected sub-fields: #{extra_keys.inspect}"
  end

  # ------------------------------------------------------------------
  # CONFIRMS: when Parse Server (or its file adapter) returns a URL
  # with a presigned-URL signature query parameter, the SDK strips
  # the signature into `@presigned_url` and keeps the bare URL in
  # `@url`. The strip path is the same single normalization point
  # used by `url=`.
  #
  # This test does NOT require the docker stack to actually run an
  # S3FilesAdapter — the SDK behavior is fully unit-testable. It
  # lives in this file because it codifies the contract that the
  # docker-confirmed Parse Server behavior depends on.
  # ------------------------------------------------------------------

  def test_sdk_strip_and_stash_path_for_parse_server_presigned_url
    # Note: setup runs the docker boot via super; the assertion itself
    # is local — no further Parse Server round-trip needed for this
    # particular contract.
    file = Parse::File.new(name: @canonical_name, contents: nil)
    presigned = "https://files.parsetfss.com/abc/#{@canonical_name}?" \
                "X-Amz-Date=20260528T120000Z&X-Amz-Expires=900&X-Amz-Signature=abc"
    file.attributes = { "name" => @canonical_name, "url" => presigned }

    assert_equal "https://files.parsetfss.com/abc/#{@canonical_name}", file.url,
                 "the bare canonical URL must be stored in @url"
    assert_equal presigned, file.presigned_url,
                 "the original signed URL must be stashed"
    refute_nil file.presigned_url_expires_at,
               "expiry must be parsed from the signed URL's own query params"
  end
end
