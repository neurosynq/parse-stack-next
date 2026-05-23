require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"
require "securerandom"

# File upload from the SDK-as-client side. Parse Server treats POST
# /files as a privileged-ish endpoint: by default it requires either
# the master key OR an authenticated session, depending on server
# config. We assert both pathways: anonymous client fails (or, if the
# server permits public uploads, the file survives but only because of
# explicit permissive config — not master-key smuggling), and
# authenticated client upload succeeds and round-trips through a
# Parse::Object pointer.
class ClientFilePost < Parse::Object
  parse_class "ClientFilePost"
  property :title, :string
  property :attachment, :file
end

class ClientRestFilesIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
    @user, @password = seed_client_user("files")
  end

  # --------------------------------------------------------------------
  # Authenticated client can upload a file and attach it to a row.
  # --------------------------------------------------------------------
  def test_authed_client_can_upload_and_attach_file
    as_client do
      me = Parse::User.login(@user.username, @password)

      contents = "hello-#{SecureRandom.hex(4)}"
      filename = "note_#{SecureRandom.hex(3)}.txt"
      response = Parse.client.create_file(
        filename, contents, "text/plain",
        session_token: me.session_token, use_master_key: false,
      )
      assert response.success?, "authed file upload must succeed (#{response.error&.inspect})"
      file_name = response.result["name"]
      file_url  = response.result["url"]
      refute_nil file_name
      refute_nil file_url
      assert file_name.end_with?(".txt"), "server-assigned name should preserve extension"

      # Attach to a row.
      file = Parse::File.new(file_name, nil, "text/plain")
      file.url = file_url
      post = ClientFilePost.new(title: "with-file", attachment: file)
      assert post.save(session: me.session_token)

      with_master_key do
        roundtrip = ClientFilePost.find(post.id)
        refute_nil roundtrip.attachment
        assert_equal file_name, roundtrip.attachment.name
      end
    end
  end

  # --------------------------------------------------------------------
  # Anonymous file upload: behavior depends on server's fileUpload config.
  # The docker test stack ships defaults; we assert that EITHER the
  # request is rejected OR (if accepted) it must not have used master key.
  # This codifies "the SDK isn't smuggling admin credentials into anon
  # file uploads."
  # --------------------------------------------------------------------
  def test_anonymous_upload_does_not_use_master_key
    as_client do
      contents = "anon-#{SecureRandom.hex(4)}"
      filename = "anon_#{SecureRandom.hex(3)}.txt"

      begin
        response = Parse.client.create_file(filename, contents, "text/plain")
        # If it succeeded, that's purely because Parse Server's
        # fileUpload.anonymousUsers was on. We can't disprove that from
        # the SDK side — but we CAN confirm the master key wasn't sent
        # by re-checking the client state.
        assert_nil Parse::Client.client.master_key,
                   "default client must not carry master key on anon upload"
      rescue Parse::Error => e
        # Permitted outcome too — Parse Server rejected the anonymous
        # upload. The assertion is that it produced a clean auth error,
        # not a 500.
        assert_match(/permission|forbidden|master|unauthorized|file upload/i, e.message,
                     "anon upload rejection must be an auth-class error, got: #{e.message}")
      end
    end
  end

  # --------------------------------------------------------------------
  # Parse::File#save (the convenience surface) under client mode
  # uses Parse.client implicitly — so the request inherits whatever
  # the default client is configured with. With no master key, the
  # upload should still succeed if the server permits authenticated
  # uploads (we can't pass a session token through Parse::File#save
  # directly today). Skip if anon uploads are disallowed.
  # --------------------------------------------------------------------
  def test_parse_file_convenience_save_under_client_mode
    as_client do
      file = Parse::File.new("conv_#{SecureRandom.hex(3)}.txt", "convenience-payload", "text/plain")

      begin
        result = file.save
        if result
          refute_nil file.url
          refute file.url.empty?
          assert_nil Parse::Client.client.master_key,
                     "Parse::File#save must not invent a master key"
        else
          # save returns false on server-side rejection; that's also fine.
          assert true
        end
      rescue Parse::Error => e
        skip "server rejects anonymous Parse::File#save: #{e.message}"
      end
    end
  end
end
