# encoding: UTF-8
# frozen_string_literal: true

require "digest"
require_relative "../../embeddings"
require_relative "../vector"

module Parse
  module Core
    # Class-level `embed` macro for `:vector` properties.
    #
    # Lets a model declare which scalar fields feed into a managed
    # embedding, and arranges for that embedding to be computed
    # automatically on save whenever the source fields change.
    #
    # @example
    #   class Document < Parse::Object
    #     property :title, :string
    #     property :body,  :string
    #     property :body_embedding, :vector, dimensions: 1536, provider: :openai
    #     embed :title, :body, into: :body_embedding
    #   end
    #
    #   doc = Document.new(title: "hello", body: "world")
    #   doc.save   # provider :openai is called once; body_embedding populated
    #
    # == Mechanics
    #
    # The class macro:
    # 1. Validates that `into:` names a declared `:vector` property with
    #    `provider:` metadata.
    # 2. Auto-declares a `<into>_digest` `:string` sibling property
    #    (override with `digest_field:`).
    # 3. Registers a `before_save` callback that re-computes the
    #    embedding whenever the SHA-256 of the concatenated source
    #    fields differs from the stored digest. On first save the digest
    #    is blank and the embedding is always populated. On a save where
    #    no source field changed the digest matches and the callback is
    #    a no-op (zero provider calls).
    # 4. Prepends a guard module that raises {ProtectedFieldError} on
    #    direct `body_embedding=` assignment from user code. The guard
    #    lifts only inside the managed write path (the before_save
    #    callback itself).
    #
    # Provider calls flow through {Parse::Embeddings.provider} — the
    # provider is resolved by name at save time, so registering a
    # provider can happen any time before the first save. Declaration
    # never makes a network call.
    #
    # == Single vector per record (v5.0)
    #
    # `embed` produces exactly one vector per record. All declared
    # source fields are concatenated (joined with "\n\n", blank values
    # skipped) and sent to the provider as a single string. There is
    # no built-in chunker in v5.0: long source text whose concatenation
    # exceeds the provider's per-call token budget will be truncated
    # provider-side, and the resulting vector will represent only the
    # leading portion of the document.
    #
    # If your source text is long-form (full articles, long
    # transcripts, multi-page PDFs), you have two options in v5.0:
    #
    # 1. Pre-chunk client-side and write each chunk as its own
    #    Parse::Object record with its own `embed` declaration.
    # 2. Maintain a dedicated `Chunk` subclass that belongs_to the
    #    parent record, with `embed :content, into: :embedding` on the
    #    chunk class itself.
    #
    # A built-in chunker + `semantic_search` agent tool are scheduled
    # for v5.1.
    module EmbedManaged
      # Raised when user code tries to assign directly to a vector
      # property that's managed by an {.embed} declaration. The intent
      # is to make it impossible to silently desync the stored vector
      # from the digest — every write goes through the digest-tracked
      # recompute path.
      class ProtectedFieldError < StandardError; end

      # Raised at class-declaration time when `embed` is called with
      # arguments that can't produce a valid managed vector — missing
      # source fields, unknown target, target without `:vector` type, or
      # `:vector` property without `provider:` metadata.
      class InvalidEmbedDeclaration < ArgumentError; end

      # Internal: name of the Thread-local key under which the managed
      # writer marks the symbol of the field it is currently writing.
      # The guard module's setter checks this key to permit a single
      # field write; the guard is otherwise closed.
      WRITER_KEY = :parse_embed_managed_writer

      # Frozen value-object capturing one `embed` or `embed_image`
      # declaration. Stored on the owning class under
      # `embed_directives[into]` and passed to
      # {EmbedManaged.recompute_embedding!} from the per-class
      # before_save callback.
      #
      # `modality` is `nil` (treated as `:text`) for {.embed}-declared
      # directives and `:image` for {.embed_image}. The image path
      # routes through `Parse::Embeddings.validate_image_url!` and
      # `Provider#embed_image` rather than `Provider#embed_text`;
      # digest tracking is over the file URL String rather than the
      # concatenated source text.
      #
      # `allow_insecure` is forwarded to {.validate_image_url!} for
      # image directives only; ignored for text.
      EmbedDirective = Struct.new(
        :sources, :into, :digest_field, :input_type, :provider_name,
        :modality, :allow_insecure,
        keyword_init: true,
      ) do
        def freeze
          sources.freeze
          super
        end

        def image?
          modality == :image
        end
      end

      # @!visibility private
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # Per-class registry of {EmbedDirective}s keyed by target vector
        # property symbol. Read by tests and tooling; written only by
        # {#embed}.
        def embed_directives
          @embed_directives ||= {}
        end

        # Declare a managed embedding. See {EmbedManaged} for the
        # full description.
        #
        # @param source_fields [Array<Symbol>] one or more scalar
        #   property names whose values are concatenated (joined with
        #   "\n\n", `nil` skipped) to form the embed input.
        # @param into [Symbol] the `:vector` property to populate.
        #   Must already be declared with `provider:` metadata.
        # @param input_type [Symbol] forwarded to
        #   {Parse::Embeddings::Provider#embed_text}. Defaults to
        #   `:search_document` (the write-side counterpart to
        #   `find_similar(text:)`'s `:search_query`).
        # @param digest_field [Symbol, nil] override for the digest
        #   sibling property. Defaults to `:"#{into}_digest"`. Auto-
        #   declared as `:string` if not already declared.
        # @return [Symbol] the target vector field name.
        # @raise [InvalidEmbedDeclaration] on declaration-time misuse.
        def embed(*source_fields, into:, input_type: :search_document, digest_field: nil)
          if source_fields.empty?
            raise InvalidEmbedDeclaration,
                  "#{self}.embed: at least one source field is required."
          end
          into = into.to_sym
          unless vector_properties.key?(into)
            raise InvalidEmbedDeclaration,
                  "#{self}.embed: `into: :#{into}` is not a declared :vector property " \
                  "(declared :vector fields: #{vector_properties.keys.inspect})."
          end
          provider_name = vector_properties.dig(into, :provider)
          if provider_name.nil?
            raise InvalidEmbedDeclaration,
                  "#{self}.embed: `into: :#{into}` has no `provider:` declared on its :vector " \
                  "property. Add `provider: :openai` (or another registered name) to the " \
                  "property declaration."
          end
          sources = source_fields.map(&:to_sym)
          missing = sources.reject { |f| fields.key?(f) }
          unless missing.empty?
            raise InvalidEmbedDeclaration,
                  "#{self}.embed: source fields #{missing.inspect} are not declared on this class."
          end

          digest_field = (digest_field || :"#{into}_digest").to_sym
          unless fields.key?(digest_field)
            property digest_field, :string
          end

          directive = EmbedDirective.new(
            sources: sources,
            into: into,
            digest_field: digest_field,
            input_type: input_type,
            provider_name: provider_name,
          ).freeze
          embed_directives[into] = directive

          callback_method = :"_auto_embed_#{into}!"
          define_method(callback_method) do
            Parse::Core::EmbedManaged.recompute_embedding!(self, directive)
          end

          already_registered = _save_callbacks.any? do |cb|
            cb.kind == :before && (cb.filter.to_sym rescue cb.filter) == callback_method
          end
          before_save callback_method unless already_registered

          install_embed_writer_guard!(into, sources)

          into
        end

        # Declare a managed image embedding. Mirrors {.embed} but the
        # source field is a `:file` property (Parse::File) and the
        # provider call routes through {Parse::Embeddings::Provider#embed_image}
        # rather than `#embed_text`. v5.1 ships URL-only: the SDK
        # extracts the file's URL, validates it through
        # {Parse::Embeddings.validate_image_url!} (sentinel-gated egress
        # opt-in, CIDR / port / host allowlist), and forwards the
        # canonicalized URL to the provider. The SDK does NOT download
        # image bytes — bytes-fetch is the v5.3 path.
        #
        # **Digest is the URL string, not the file contents.** Replacing
        # the Parse::File with one pointing to a different URL re-embeds;
        # re-saving the same URL is a no-op (zero provider calls).
        # Cloud-stored Parse files have stable URLs unless overwritten,
        # so this is the right cache key for most uploads. If you mutate
        # the underlying bytes at the SAME URL (e.g. PUT-replace on S3
        # without renaming), the embedding will NOT refresh; rename the
        # file or set `:#{into}_digest` to nil and resave to force re-embed.
        #
        # @param source_field [Symbol] one `:file` property whose URL
        #   feeds the provider. (v5.1 accepts a single source per
        #   directive; multi-image-per-record support is deferred.)
        # @param into [Symbol] the `:vector` property to populate.
        #   Must already be declared with `provider:` metadata.
        # @param input_type [Symbol] forwarded to {Provider#embed_image}.
        #   Defaults to `:search_document`.
        # @param digest_field [Symbol, nil] override for the URL-digest
        #   sibling. Defaults to `:"#{into}_digest"`. Auto-declared as
        #   `:string` if not already declared.
        # @param allow_insecure [Boolean] forwarded to
        #   {Parse::Embeddings.validate_image_url!}; permit `http://`
        #   for local-dev CDN proxies. Default false.
        # @return [Symbol] the target vector field name.
        # @raise [InvalidEmbedDeclaration] on declaration-time misuse.
        def embed_image(source_field, into:, input_type: :search_document,
                        digest_field: nil, allow_insecure: false)
          into = into.to_sym
          unless vector_properties.key?(into)
            raise InvalidEmbedDeclaration,
                  "#{self}.embed_image: `into: :#{into}` is not a declared :vector property " \
                  "(declared :vector fields: #{vector_properties.keys.inspect})."
          end
          provider_name = vector_properties.dig(into, :provider)
          if provider_name.nil?
            raise InvalidEmbedDeclaration,
                  "#{self}.embed_image: `into: :#{into}` has no `provider:` declared on its " \
                  ":vector property. Add `provider: :voyage` (or another registered name) " \
                  "to the property declaration."
          end

          source = source_field.to_sym
          unless fields.key?(source)
            raise InvalidEmbedDeclaration,
                  "#{self}.embed_image: source field #{source.inspect} is not declared on this class."
          end
          unless fields[source] == :file
            raise InvalidEmbedDeclaration,
                  "#{self}.embed_image: source field #{source.inspect} must be a :file property " \
                  "(got #{fields[source].inspect}). v5.1 image embedding accepts Parse::File " \
                  "sources only — text sources go through `embed`."
          end

          digest_field = (digest_field || :"#{into}_digest").to_sym
          unless fields.key?(digest_field)
            property digest_field, :string
          end

          directive = EmbedDirective.new(
            sources: [source],
            into: into,
            digest_field: digest_field,
            input_type: input_type,
            provider_name: provider_name,
            modality: :image,
            allow_insecure: allow_insecure,
          ).freeze
          embed_directives[into] = directive

          callback_method = :"_auto_embed_#{into}!"
          define_method(callback_method) do
            Parse::Core::EmbedManaged.recompute_embedding!(self, directive)
          end

          already_registered = _save_callbacks.any? do |cb|
            cb.kind == :before && (cb.filter.to_sym rescue cb.filter) == callback_method
          end
          before_save callback_method unless already_registered

          install_embed_writer_guard!(into, [source])

          into
        end

        # @!visibility private
        # Prepend a module that intercepts the public `<into>=` setter
        # and raises {ProtectedFieldError} unless the current thread has
        # marked itself as the managed writer for this field.
        def install_embed_writer_guard!(into, sources)
          setter = :"#{into}="
          guard = Module.new
          field_sym = into
          source_list = sources
          guard.module_eval do
            define_method(setter) do |val|
              if Thread.current[Parse::Core::EmbedManaged::WRITER_KEY] == field_sym
                super(val)
              else
                raise Parse::Core::EmbedManaged::ProtectedFieldError,
                      "#{self.class}##{field_sym} is managed by `embed` and cannot be " \
                      "assigned directly. Update source fields #{source_list.inspect} " \
                      "and save; the embedding will be recomputed automatically."
              end
            end
          end
          prepend(guard)
        end
      end

      # @!visibility private
      # Run the managed-write path with the writer guard lifted for
      # exactly one field. Restores the prior value of the Thread-local
      # on exit so nested calls (and unrelated callers on the same
      # thread) are unaffected.
      def self.with_writer(field)
        prev = Thread.current[WRITER_KEY]
        Thread.current[WRITER_KEY] = field
        yield
      ensure
        Thread.current[WRITER_KEY] = prev
      end

      # @!visibility private
      # before_save body. Dispatches on `directive.modality`: text
      # directives concatenate source-field values and call
      # `Provider#embed_text`; image directives extract the source
      # Parse::File's URL, validate it via
      # `Parse::Embeddings.validate_image_url!`, and call
      # `Provider#embed_image`. Digest tracking elides the provider
      # call when the source has not changed since last save.
      def self.recompute_embedding!(record, directive)
        input = build_source_input(record, directive)
        stored_digest = record.public_send(directive.digest_field)
        target_present = !record.public_send(directive.into).nil?

        if input.nil? || input.empty?
          if target_present || !stored_digest.nil?
            with_writer(directive.into) do
              record.public_send(:"#{directive.into}=", nil)
            end
            record.public_send(:"#{directive.digest_field}=", nil)
          end
          return
        end

        digest = digest_for(input)
        return if stored_digest == digest && target_present

        provider = Parse::Embeddings.provider(directive.provider_name)
        vectors = call_provider(provider, directive, input)
        unless vectors.is_a?(Array) && vectors.length == 1 && vectors.first.is_a?(Array)
          raise Parse::Embeddings::InvalidResponseError,
                "Parse::Core::EmbedManaged (#{record.class}##{directive.into}): provider " \
                "#{directive.provider_name.inspect} did not return a single vector " \
                "(got #{vectors.inspect[0, 80]})."
        end
        vector = Parse::Vector.new(vectors.first)
        expected_dims = record.class.vector_properties.dig(directive.into, :dimensions)
        if expected_dims && vector.dimensions != expected_dims
          raise Parse::Embeddings::InvalidResponseError,
                "Parse::Core::EmbedManaged (#{record.class}##{directive.into}): provider " \
                "#{directive.provider_name.inspect} returned #{vector.dimensions}-dim vector " \
                "but property declares dimensions: #{expected_dims}."
        end

        with_writer(directive.into) do
          record.public_send(:"#{directive.into}=", vector)
        end
        record.public_send(:"#{directive.digest_field}=", digest)
      end

      # @!visibility private
      # Build the provider input for `directive`: concatenated text for
      # text directives; the raw image URL for image directives.
      # Returns `nil` (treated as "clear the embedding") when the source
      # is absent, empty, or — for images — has no URL.
      #
      # **Image path does not validate here.** Validation runs once,
      # inside the provider's `embed_image` call. Validating here
      # would double-resolve every URL (round-2 audit LOW #3) since
      # provider implementations call `validate_image_url!` again.
      # The digest is computed from the raw URL string, which is fine
      # — the digest is a content fingerprint, not a security boundary.
      # If validation fails, the provider raises `InvalidImageURL` /
      # `ConfirmationRequired` from inside `recompute_embedding!`, which
      # surfaces from `before_save` exactly as before.
      def self.build_source_input(record, directive)
        if directive.image?
          source_field = directive.sources.first
          file = record.public_send(source_field)
          return nil if file.nil?
          url = file.respond_to?(:url) ? file.url : nil
          return nil if url.nil? || url.to_s.empty?
          url.to_s
        else
          build_source_text(record, directive.sources)
        end
      end

      # @!visibility private
      # Dispatch the provider call based on directive modality.
      def self.call_provider(provider, directive, input)
        if directive.image?
          provider.embed_image([input],
            input_type: directive.input_type,
            allow_insecure: directive.allow_insecure ? true : false)
        else
          provider.embed_text([input], input_type: directive.input_type)
        end
      end

      # @!visibility private
      # Concatenate source-field string values. `nil` and blank entries
      # are skipped; remaining values are joined with a double newline.
      # If every source is blank the result is the empty string, which
      # the caller treats as "clear the embedding".
      def self.build_source_text(record, sources)
        sources.map { |f| record.public_send(f).to_s }
               .reject(&:empty?)
               .join("\n\n")
      end

      # @!visibility private
      # Truncated SHA-256 hex of the source text. 32 hex chars (128
      # bits) is plenty for a non-cryptographic change detector and
      # keeps the digest sibling field compact.
      def self.digest_for(text)
        Digest::SHA256.hexdigest(text)[0, 32]
      end
    end
  end
end
