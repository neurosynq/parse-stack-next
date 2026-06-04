# encoding: UTF-8
# frozen_string_literal: true

require "active_support"
require "active_support/json"
require "securerandom"

module Parse
  #This class represents a Parse request.
  class Request
    # @!attribute [rw] method
    #   @return [String] the HTTP method used for this request.

    # @!attribute [rw] path
    #   @return [String] the uri path.

    # @!attribute [rw] body
    #   @return [Hash] the body of this request.

    # TODO: Document opts and cache options.

    # @!attribute [rw] opts
    #   @return [Hash] a set of options for this request.
    # @!attribute [rw] cache
    #   @return [Boolean]
    attr_accessor :method, :path, :body, :headers, :opts, :cache

    # @!visibility private
    # Used to correlate batching requests with their responses.
    attr_accessor :tag

    # @!attribute [rw] request_id
    #   @return [String] unique identifier for this request to enable idempotency
    attr_accessor :request_id

    # Class-level configuration for request ID behavior
    class << self
      # @!attribute [rw] enable_request_id
      #   @return [Boolean] whether to automatically generate request IDs for idempotency
      attr_accessor :enable_request_id

      # @!attribute [rw] request_id_header
      #   @return [String] the header name to use for request IDs
      attr_accessor :request_id_header

      # @!attribute [rw] idempotent_methods
      #   @return [Array<Symbol>] HTTP methods that should include request IDs
      attr_accessor :idempotent_methods

      # @!attribute [rw] assume_server_idempotency
      #   @return [Boolean] operator assertion that the Parse Server is
      #     configured with `idempotencyOptions` covering the write paths the
      #     SDK targets. When true, a request that carries a stable
      #     `X-Parse-Request-Id` header becomes safe for {Parse::Client} to
      #     transparently RETRY on an ambiguous failure (500/503/dropped
      #     connection) even when it is a POST or an atomic-op write — Parse
      #     Server deduplicates the replay server-side, so the second delivery
      #     is a no-op that returns the original result.
      #
      #     Default false. Sending the `X-Parse-Request-Id` header is harmless
      #     on its own, but ASSUMING the server deduplicates when it does not
      #     would double-apply the write on retry. Only set this true when
      #     Parse Server's `idempotencyOptions` is actually configured to cover
      #     those paths (it is OFF by default on Parse Server).
      attr_accessor :assume_server_idempotency
    end

    # Default configuration
    self.enable_request_id = true  # Enabled by default for production safety
    self.request_id_header = "X-Parse-Request-Id"  # Standard Parse header
    self.idempotent_methods = [:post, :put, :patch]  # Methods that can benefit from idempotency
    # OFF by default: the client cannot know whether the server deduplicates,
    # so it never assumes retry-safety for writes unless the operator opts in.
    self.assume_server_idempotency = false

    # Creates a new request
    # @param method [String] the HTTP method
    # @param uri [String] the API path of the request (without the host)
    # @param body [Hash] the body (or parameters) of this request.
    # @param headers [Hash] additional headers to send in this request.
    # @param opts [Hash] additional optional parameters.
    # @option opts [String] :request_id custom request ID for idempotency
    # @option opts [Boolean] :idempotent force enable/disable idempotency for this request
    def initialize(method, uri, body: nil, headers: nil, opts: {})
      @tag = 0
      method = method.downcase.to_sym
      unless method == :get || method == :put || method == :post || method == :delete
        raise ArgumentError, "Invalid method #{method} for request : '#{uri}'"
      end

      self.method = method
      self.path = uri
      self.body = body
      self.headers = headers || {}
      self.opts = opts || {}

      # Handle request ID for idempotency
      setup_request_id
    end

    # The parameters of this request if the HTTP method is GET.
    # @return [Hash]
    def query
      body if @method == :get
    end

    # @return [Hash] JSON encoded hash
    def as_json
      signature.as_json
    end

    # @return [Boolean]
    def ==(r)
      return false unless r.is_a?(Request)
      @method == r.method && @path == r.path && @body == r.body && @headers == r.headers
    end

    # Signature provies a way for us to compare different requests objects.
    # Two requests objects are the same if they have the same signature.
    # @return [Hash] A hash representing this request.
    def signature
      { method: @method.upcase, path: @path, body: @body }
    end

    # @!visibility private
    def inspect
      "#<#{self.class} @method=#{@method} @path='#{@path}'>"
    end

    # @return [String]
    def to_s
      "#{@method.to_s.upcase} #{@path}"
    end

    private

    # Sets up request ID for idempotency based on configuration and request properties
    def setup_request_id
      # Check if idempotency should be enabled for this request
      should_use_request_id = determine_idempotency_requirement

      return unless should_use_request_id

      header_name = self.class.request_id_header

      # If a request id is already on the headers — e.g. a retry re-builds the
      # Request with the same headers hash carried over from the first attempt
      # — adopt it so the `request_id` ivar matches the value actually on the
      # wire. Generating a fresh UUID here while the `||=` below leaves the old
      # header in place would silently diverge the ivar from the sent header.
      existing = @headers[header_name]
      if existing && !existing.to_s.empty?
        @request_id = existing
        return
      end

      # Use custom request ID if provided, otherwise generate one
      @request_id = @opts[:request_id] || generate_request_id

      # Add request ID to headers if not already present
      @headers[header_name] ||= @request_id
    end

    # Determines if this request should use a request ID for idempotency
    # @return [Boolean]
    def determine_idempotency_requirement
      # Explicit override in opts takes precedence
      return @opts[:idempotent] if @opts.key?(:idempotent)

      # Check if request ID is already in headers (manually added)
      return true if @headers[self.class.request_id_header]

      # Check global configuration and method
      return false unless self.class.enable_request_id
      return false unless self.class.idempotent_methods.include?(@method)

      # Don't add request IDs to certain paths that are inherently idempotent
      # or where Parse handles idempotency differently
      return false if non_idempotent_path?

      true
    end

    # Checks if the request path should not use request IDs
    # @return [Boolean]
    def non_idempotent_path?
      # GET requests are naturally idempotent
      return true if @method == :get

      # Some Parse endpoints handle their own idempotency or shouldn't be retried
      non_idempotent_patterns = [
        %r{/sessions},           # Session creation/management
        %r{/logout},             # Logout operations
        %r{/requestPasswordReset}, # Password reset requests
        %r{/functions/},         # Cloud functions (may have their own logic)
        %r{/jobs/},              # Background jobs
        %r{/events/},            # Analytics events
        %r{/push},                # Push notifications
      ]

      non_idempotent_patterns.any? { |pattern| @path =~ pattern }
    end

    # Generates a unique request ID
    # @return [String] a unique identifier for this request
    def generate_request_id
      # Use a format that identifies the request came from Ruby Parse Stack
      # and includes a UUID for uniqueness
      "_RB_#{SecureRandom.uuid}"
    end

    public

    # Enables idempotency for this specific request
    # @param custom_id [String] optional custom request ID to use
    # @return [self] for method chaining
    def with_idempotency(custom_id = nil)
      @opts[:idempotent] = true
      @opts[:request_id] = custom_id if custom_id
      setup_request_id
      self
    end

    # Disables idempotency for this specific request
    # @return [self] for method chaining
    def without_idempotency
      @opts[:idempotent] = false
      @request_id = nil
      @headers.delete(self.class.request_id_header)
      self
    end

    # Checks if this request has idempotency enabled
    # @return [Boolean]
    def idempotent?
      @request_id.present? && @headers[self.class.request_id_header].present?
    end

    # Class methods for configuration

    # Enables request ID generation globally
    # @param methods [Array<Symbol>] HTTP methods to apply idempotency to
    # @param header [String] header name to use for request IDs
    # @param assume_server_dedup [Boolean, nil] when non-nil, also sets
    #   {assume_server_idempotency} — pass `true` ONLY when Parse Server's
    #   `idempotencyOptions` is configured, to additionally make writes
    #   retry-safe. Leave nil (default) to send the header without changing
    #   the retry posture.
    def self.enable_idempotency!(methods: [:post, :put, :patch], header: "X-Parse-Request-Id", assume_server_dedup: nil)
      self.enable_request_id = true
      self.idempotent_methods = methods
      self.request_id_header = header
      self.assume_server_idempotency = assume_server_dedup unless assume_server_dedup.nil?
    end

    # Disables request ID generation globally. Also clears
    # {assume_server_idempotency} so writes are never treated as retry-safe
    # once the header is no longer sent.
    def self.disable_idempotency!
      self.enable_request_id = false
      self.assume_server_idempotency = false
    end

    # Configures idempotency settings
    # @param enabled [Boolean] whether to enable idempotency
    # @param methods [Array<Symbol>] HTTP methods to apply idempotency to
    # @param header [String] header name to use for request IDs
    # @param assume_server_dedup [Boolean] sets {assume_server_idempotency}
    #   (default false). Pass true ONLY when Parse Server `idempotencyOptions`
    #   is configured for the targeted paths.
    def self.configure_idempotency(enabled: true, methods: [:post, :put, :patch], header: "X-Parse-Request-Id", assume_server_dedup: false)
      self.enable_request_id = enabled
      self.idempotent_methods = methods
      self.request_id_header = header
      self.assume_server_idempotency = assume_server_dedup
    end
  end
end
