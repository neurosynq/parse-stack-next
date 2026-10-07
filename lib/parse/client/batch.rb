# encoding: UTF-8
# frozen_string_literal: true

require "digest"
require_relative "request"
require_relative "response"

module Parse
  # Declared here because this file loads before lib/parse/client.rb, which
  # reopens it with the same superclass and defines its subclasses.
  class Error < StandardError; end

  # Create a new batch operation.
  # @param reqs [Array<Parse::Request>] a set of requests to batch.
  # @return [BatchOperation] a new {BatchOperation} with the given change requests.
  def self.batch(reqs = nil)
    BatchOperation.new(reqs)
  end

  # This class provides a standard way to submit, manage and process batch operations
  # for Parse::Objects and associations.
  #
  # Batch requests are supported implicitly and intelligently through an
  # extension of array. When an array of Parse::Object subclasses is saved,
  # Parse-Stack will batch all possible save operations for the objects in the
  # array that have changed. It will also batch save 50 at a time until all items
  # in the array are saved. Note: Parse does not allow batch saving Parse::User objects.
  #
  #  songs = Songs.first 1000 #first 1000 songs
  #  songs.each do |song|
  #   # ... modify song ...
  #  end
  #
  #  # will batch save 50 items at a time until all are saved.
  #  songs.save
  #
  # The objects do not have to be of the same collection in order to be supported in the
  # batch request.
  # @see Array.save
  # @see Array.destroy
  class BatchOperation
    include Enumerable

    # Raised when a batch would send requests built for different
    # credentials (a different client, an explicit session token, or an
    # explicit `use_master_key:`) as one transaction. Parse Server runs every
    # sub-request of a `POST /batch` under that call's own credentials, so a
    # mixed transaction cannot honor each request's authority. Nothing is
    # sent when this is raised.
    class MixedAuthorityError < Parse::Error; end

    # @!visibility private
    # A comparable identity for the credentials a client sends: server URL,
    # application id, digests of the REST and master keys, and its bound
    # session token. Two client objects with the same configuration (for
    # example a class client memoized before a second `Parse.setup`) have the
    # same fingerprint and are batched together. The keys are digested so the
    # fingerprint never holds a secret.
    # @param c [Parse::Client]
    # @return [Array]
    def self.credential_fingerprint(c)
      return [:client, c.object_id] unless c.respond_to?(:application_id) && c.respond_to?(:server_url)
      digest = lambda do |v|
        v.nil? || v.to_s.empty? ? nil : ::Digest::SHA256.hexdigest(v.to_s)
      end
      bound = c.respond_to?(:session_token) ? c.session_token : nil
      [c.server_url.to_s.sub(%r{/+\z}, ""), c.application_id.to_s,
       digest.call(c.respond_to?(:api_key) ? c.api_key : nil),
       digest.call(c.respond_to?(:master_key) ? c.master_key : nil),
       digest.call(bound)]
    end

    # Default number of threads used to dispatch batch segments concurrently.
    # Raise via `Parse::BatchOperation.parallelism = N` (or pass `parallelism:`
    # to `#submit`) for higher throughput on bulk writes; 2 is intentionally
    # conservative to avoid overwhelming smaller Parse Server deployments.
    DEFAULT_PARALLELISM = 2

    class << self
      attr_writer :parallelism

      def parallelism
        @parallelism || DEFAULT_PARALLELISM
      end
    end

    # @!attribute requests
    #  @return [Array] the set of requests in this batch.

    # @!attribute responses
    #  @return [Array] the set of responses from this batch.

    # @!attribute transaction
    #  @return [Boolean] whether this batch should be executed as a transaction.
    attr_accessor :requests, :responses, :transaction

    # @return [Parse::Client] the client used for requests that were not
    #   built for a specific client. Requests built from an object
    #   ({Parse::Object#change_requests}, {Parse::Object#destroy_request})
    #   carry their class's client and are sent through it.
    def client
      @client ||= Parse::Client.client
    end

    # Set the client used for requests that were not built for a specific
    # client. A transaction whose requests were built for another client
    # raises {MixedAuthorityError}.
    # @param c [Parse::Client]
    def client=(c)
      @client = c
      @explicit_client = !c.nil?
    end

    # @!visibility private
    # Credentials (`session_token:`, `use_master_key:`) applied to requests
    # that name none of their own. Set by {Parse::API::Batch#batch_request}
    # when it routes a mixed batch through {#submit}.
    # @return [Hash]
    def batch_defaults
      @batch_defaults || {}
    end

    # @!visibility private
    attr_writer :batch_defaults

    # @param reqs [Array<Parse::Request>] an array of requests.
    # @param transaction [Boolean] whether to execute as a transaction.
    def initialize(reqs = nil, transaction: false)
      @requests = []
      @responses = []
      @submitted = false
      @transaction = transaction
      reqs = [reqs] unless reqs.is_a?(Enumerable)
      reqs.each { |r| add(r) } if reqs.is_a?(Enumerable)
    end

    # Add an additional request to this batch.
    #
    # A request tagged to a Parse object (see {Parse::Request#tag}) is skipped
    # when the batch already holds an identical request for that same object,
    # so adding an object twice does not send its changes twice. Untagged
    # requests are always kept: two identical raw requests (for example two
    # Increment operations) are two writes and are both sent.
    # @overload add(req)
    #  @param req [Parse::Request] the request to append.
    #  @return [Array<Parse::Request>] the set of requests.
    # @overload add(batch)
    #  @param req [Parse::BatchOperation] add all the requests from this batch operation.
    #  @return [Array<Parse::Request>] the set of requests.
    def add(req)
      incoming = if req.is_a?(BatchOperation)
          req.requests
        elsif req.respond_to?(:change_requests)
          req.change_requests
        elsif req.is_a?(Array)
          req
        else
          [req]
        end
      incoming.each do |r|
        next unless r.is_a?(Parse::Request)
        next if duplicate_object_request?(r)
        @requests.push(r)
      end
      @requests
    end

    # This method is for interoperability with Parse::Object instances.
    # @see Parse::Object#change_requests
    def change_requests
      @requests
    end

    # @return [Array]
    def each(&block)
      return enum_for(:each) unless block_given?
      @requests.each(&block)
    end

    # @return [Hash] a formatted payload for the batch request.
    def as_json(*args)
      payload = { requests: requests }
      payload[:transaction] = true if @transaction
      payload.as_json
    end

    # @return [Integer] the number of requests in the batch.
    def count
      @requests.count
    end

    # Remove all requests in this batch.
    # @return [Array]
    def clear!
      @requests.clear
    end

    # @return [Boolean] true if every response in the batch succeeded. A
    #   batch that was submitted with no requests is successful; one that has
    #   not been submitted is not.
    def success?
      return @submitted == true if @responses.empty?
      @responses.all? { |r| r.respond_to?(:success?) && r.success? }
    end

    # @return [Boolean] true if at least one response in the batch failed.
    def error?
      return false if @responses.empty?
      !success?
    end

    # Submit the batch operation in chunks until they are all complete. In general,
    # Parse limits requests in each batch to 50 and it is possible that a {BatchOperation}
    # instance contains more than 50 requests. This method will slice up the array of
    # request and send them based on the `segment` amount until they have all been submitted.
    #
    # The returned array always has one response per request, in request
    # order. When a chunk fails as a whole (an HTTP error, or a response that
    # cannot be matched to its requests), every request in that chunk gets a
    # failed response, so a failure never shifts results onto other requests.
    #
    # A transactional batch (`transaction: true`) is never split. All of its
    # requests go to Parse Server in one `POST /batch` with `transaction: true`,
    # which commits or rolls back as a unit, regardless of `segment`. Parse
    # Server has no fixed sub-request limit; a server configured with
    # `requestComplexity.batchRequestLimit` rejects an oversized transaction
    # for non-master callers, and nothing is written.
    #
    # When a chunk raises (for example a 5xx or a dropped connection), the
    # other chunks are still processed and the block still sees every
    # request, with failed responses for the chunk that raised. The first
    # exception is then re-raised.
    # @param segment [Integer] the number of requests to send in each batch. Default 50.
    # @param parallelism [Integer] the number of segments dispatched in
    #   parallel. Defaults to `Parse::BatchOperation.parallelism` (2).
    # @yieldparam request [Parse::Request] a submitted request.
    # @yieldparam response [Parse::Response] the response for that request.
    # @return [Array<Parse::Response>] the corresponding set of responses for
    #  each request in the batch.
    def submit(segment = 50, parallelism: self.class.parallelism, &block)
      @responses = []
      @submitted = true
      failure = nil
      return @responses if @requests.empty?

      # Parse Server runs every sub-request under the credentials of the one
      # `POST /batch` call, so requests built for different credentials are
      # sent as separate calls, each with its own client and options. This
      # is decided before anything is sent.
      groups = authority_groups

      if @transaction
        if groups.size > 1
          raise MixedAuthorityError,
                "A transaction cannot mix requests built for different credentials " \
                "(#{groups.size} distinct clients or session/master-key options). Parse Server " \
                "runs a batch under one credential, so it cannot honor each request's own. " \
                "Save these objects in separate transactions."
        end
        group = groups.first
        if @explicit_client && self.class.credential_fingerprint(group[:client]) != self.class.credential_fingerprint(client)
          raise MixedAuthorityError,
                "This transaction's requests were built for a different client than the " \
                "one set on the batch. Use the objects' own client."
        end
        # One request, one transaction. Exceptions propagate unchanged so the
        # caller can roll back its local state.
        result = group[:client].batch_request(self, **group[:opts])
        @responses = align_responses(@requests, result)
      else
        segment = 50 if segment.nil? || segment < 1
        parallelism = 1 if parallelism.nil? || parallelism < 1
        # Each slice holds requests of one authority group, with their
        # positions in the batch, so responses go back in request order.
        slices = groups.flat_map do |g|
          g[:entries].each_slice(segment).map { |entries| [g, entries] }
        end
        outcomes = slices.threaded_map(parallelism) do |slice|
          g, entries = slice
          reqs = entries.map(&:last)
          begin
            [entries, align_responses(reqs, g[:client].batch_request(BatchOperation.new(reqs), **g[:opts])), nil]
          rescue StandardError => e
            [entries, Array.new(reqs.size) { exception_response(e) }, e]
          end
        end
        @responses = Array.new(@requests.size)
        outcomes.each do |entries, responses, _error|
          entries.each_with_index { |(index, _req), i| @responses[index] = responses[i] }
        end
        failure = outcomes.map(&:last).compact.first
      end

      @requests.zip(@responses).each(&block) if block_given?
      raise failure if failure
      @responses
    end

    alias_method :save, :submit

    private

    # Group the requests by the credentials they were built for: the client
    # (a request's own, else this batch's) plus an explicit session token
    # and an explicit `use_master_key:` from the request's options. Requests
    # with no explicit authority on this batch's client form one group sent
    # with no extra options, so an ambient `Parse.with_session`,
    # `Parse.client_mode`, or `Parse.without_master_key` applies exactly as
    # it does to a single request.
    # Credentials come from {Parse::Request#explicit_authority} (options,
    # then headers), falling back to `default_opts` for a request that names
    # none.
    # @param default_client [Parse::Client] client for requests built for none.
    # @param default_opts [Hash] `session_token:` / `use_master_key:` applied to
    #   requests that name no credentials of their own.
    # @return [Array<Hash>] groups in first-appearance order, each with
    #   `:client`, `:opts`, and `:entries` (`[index, request]` pairs).
    # @!visibility private
    def authority_groups(default_client = client, default_opts = batch_defaults)
      defaults = default_opts.is_a?(Hash) ? default_opts : {}
      groups = {}
      @requests.each_with_index do |req, index|
        target = req.respond_to?(:client) && req.client ? req.client : default_client
        # Credentials resolve as they do for a single request: options, then
        # the session-token and master-key-suppression headers.
        named = req.respond_to?(:explicit_authority) ? req.explicit_authority : {}
        token = named.key?(:session_token) ? named[:session_token] : defaults[:session_token]
        token = token.session_token if !token.nil? && token.respond_to?(:session_token)
        token = token.to_s unless token.nil?
        master = named.key?(:use_master_key) ? named[:use_master_key] : defaults[:use_master_key]
        suppress = named[:suppress_master_key] == true || defaults[:suppress_master_key] == true
        key = [self.class.credential_fingerprint(target), token, master, suppress]
        existing = groups[key]
        if existing && !existing[:client].equal?(default_client) && target.equal?(default_client)
          # Same credentials as an earlier client object: send through the
          # batch's own client.
          existing[:client] = default_client
        end
        group = groups[key] ||= begin
            call_opts = {}
            call_opts[:session_token] = token unless token.nil?
            call_opts[:use_master_key] = master unless master.nil?
            call_opts[:suppress_master_key] = true if suppress
            { client: target, opts: call_opts, entries: [] }
          end
        group[:entries] << [index, req]
      end
      groups.values
    end
    public :authority_groups

    # Whether `req` repeats a request already in the batch for the same
    # tagged object.
    def duplicate_object_request?(req)
      tag = req.tag
      return false if tag.nil? || tag == 0
      sig = req.signature
      @requests.any? { |r| r.tag == tag && r.signature == sig }
    end

    # Pair a chunk's requests with the result of its batch call, one
    # response per request.
    # @param slice [Array<Parse::Request>] the requests that were sent.
    # @param result [Array<Parse::Response>, Parse::Response] the result of
    #   {Parse::API::Batch#batch_request}.
    # @return [Array<Parse::Response>]
    def align_responses(slice, result)
      if result.is_a?(Array)
        slice.each_with_index.map do |_req, i|
          entry = result[i]
          next entry if entry.is_a?(Parse::Response)
          Parse::Response.error_response(
            Parse::Response::ERROR_INTERNAL,
            "Batch response had #{result.size} results for #{slice.size} requests",
          )
        end
      elsif result.is_a?(Parse::Response) && result.error?
        slice.map do
          Parse::Response.error_response(result.code, result.error, http_status: result.http_status)
        end
      else
        slice.map do
          Parse::Response.error_response(Parse::Response::ERROR_INTERNAL, "Malformed batch response")
        end
      end
    end

    # A failed response standing in for a request whose chunk raised.
    def exception_response(error)
      code = Parse::Response::ERROR_INTERNAL
      inner = error.respond_to?(:response) ? error.response : nil
      code = inner.code if inner.respond_to?(:code) && inner.code.is_a?(Integer)
      Parse::Response.error_response(code, "#{error.class}: #{error.message}")
    end
  end
end

class Array

  # Submit a batch request for deleting a set of Parse::Objects.
  #
  # Each object whose delete succeeds has its local state updated the same
  # way {Parse::Object#destroy} updates it. Objects whose delete fails are
  # left untouched; inspect the returned batch's responses to find them.
  # Destroy callbacks are not run. Every {Parse::Session} and {Parse::User}
  # whose delete succeeded, or reported "object not found" (the row is
  # already gone, for example revoked elsewhere), is dropped from its
  # client's identity plane, as their single-object destroy does.
  # @example
  #  # assume Post and Author are Parse models
  #  author = Author.first
  #  posts = Post.all author: author
  #  posts.destroy # batch destroy request
  # @param session [String, #session_token, nil] send every delete as this
  #   user (ACL and CLP enforced) instead of each object's client default.
  # @return [Parse::BatchOperation] the batch operation performed.
  # @raise ArgumentError if the array is not empty and holds no Parse objects.
  # @raise Parse::BatchOperation::MixedAuthorityError never for a destroy;
  #   objects bound to different clients are deleted in separate calls.
  # @see Parse::BatchOperation
  def destroy(session: nil)
    token = Parse::BatchOperation.session_token_for!(session)
    targets = select { |o| o.respond_to?(:destroy_request) }
    if targets.empty? && !empty?
      raise ArgumentError, "Array#destroy requires Parse::Object elements; " \
                           "this array holds none (#{first.class})"
    end
    # A session deleted from a pointer or a partial fetch carries no token or
    # owner to drop from the identity cache; look them up first, in one
    # query per client.
    Parse::Session.send(:_preload_identity_for_destroy!, targets, session_token: token) if defined?(Parse::Session)
    _destroy_batch(targets, token)
  ensure
    # A looked-up session token is a live credential; never leave it on an
    # object whose delete was skipped or whose batch raised.
    targets&.each { |o| o.send(:_clear_identity_for_destroy!) if _batch_identity_hook?(o, :_clear_identity_for_destroy!) }
  end

  # @!visibility private
  def _destroy_batch(targets, token = nil)
    batch = Parse::BatchOperation.new
    objects = {}
    targets.each do |o|
      next if objects.key?(o.object_id)
      r = o.destroy_request
      next if r.nil?
      r.opts[:session_token] = token if token
      objects[o.object_id] = o
      batch.add(r)
    end
    batch.submit do |request, response|
      o = objects[request.tag]
      next unless o
      # Sessions and users drop their identity-plane entries when the delete
      # applied or the row is already gone ("object not found"), so a revoked
      # token stops resolving now. They decide from the response; a denied
      # delete leaves the cache alone.
      o.send(:_after_batch_destroy, response) if _batch_identity_hook?(o, :_after_batch_destroy)
      next unless response.respond_to?(:success?) && response.success?
      # Mirror Parse::Object#destroy: keep the id and mark the object
      # destroyed so it reports `destroyed?` and a later save refuses.
      o.instance_variable_set(:@_destroyed, true)
      o.changes_applied! if o.respond_to?(:changes_applied!)
    end
    batch
  end
  private :_destroy_batch

  # Whether `o`'s class defines the internal (non-public) identity hook
  # `name`. Checked on the class rather than with `respond_to?(name, true)`
  # so a duck-typed element overriding `respond_to?` cannot break the batch.
  # @!visibility private
  def _batch_identity_hook?(o, name)
    klass = o.class
    klass.private_method_defined?(name) || klass.method_defined?(name)
  end
  private :_batch_identity_hook?

  # Do not alias method as :delete is already part of array.
  # alias_method :delete, :destroy

  # Submit a batch request for saving a set of Parse::Objects.
  # Batch requests are supported implicitly and intelligently through an
  # extension of array. When an array of Parse::Object subclasses is saved,
  # Parse-Stack will batch all possible save operations for the objects in the
  # array that have changed. It will also batch save 50 at a time until all items
  # in the array are saved. Note: Parse does not allow batch saving Parse::User objects.
  #
  # Each object is updated only from its own responses. An object whose
  # requests all succeed gets its id and timestamps and has its changes
  # cleared. When an object has several requests (an attribute update plus
  # relation updates) and only some succeed, the fields written by the
  # successful requests are cleared and the rest stay dirty, so a later save
  # resends only what failed. An object listed more than once is saved once.
  # Elements that are not Parse objects are skipped.
  # @note The objects of the array to be saved do not all have to be of the same collection.
  # @param merge [Boolean] whether to merge the updated changes to the series of
  #  objects back to the original ones submitted. If you don't need the original objects
  #  to be updated with the changes, set this to false for improved performance.
  # @param force [Boolean] Do not skip objects that do not have pending changes (dirty tracking).
  # @param session [String, #session_token, nil] send every write as this
  #   user (ACL and CLP enforced) instead of each object's client default.
  # @example
  #  # assume Post and Author are Parse models
  #  author = Author.first
  #  posts = Post.first 100
  #  posts.each { |post| post.author = author }
  #  posts.save # batch save
  # @note Each write is sent with the credentials of its object's class
  #  client, as a single {Parse::Object#save} is. Objects bound to different
  #  clients are saved in separate batch calls.
  # @return [Parse::BatchOperation] the batch operation performed.
  # @raise ArgumentError if the array is not empty and holds no Parse objects.
  # @see Parse::BatchOperation
  def save(merge: true, force: false, session: nil)
    token = Parse::BatchOperation.session_token_for!(session)
    targets = select { |o| o.is_a?(Parse::Object) }
    if targets.empty? && !empty?
      raise ArgumentError, "Array#save requires Parse::Object elements; " \
                           "this array holds none (#{first.class})"
    end
    batch = Parse::BatchOperation.new
    objects = {}
    targets.each do |o|
      next if objects.key?(o.object_id)
      objects[o.object_id] = o
      reqs = o.change_requests(force)
      reqs.each { |r| r.opts[:session_token] = token } if token
      batch.add reqs
    end
    if merge == false
      batch.submit
      return batch
    end
    outcomes = Hash.new { |h, k| h[k] = [] }
    begin
      batch.submit do |request, response|
        outcomes[request.tag] << [request, response] if objects.key?(request.tag)
      end
    ensure
      # Apply what landed even when a chunk raised, so a successful create is
      # never left looking new (which would create it again on the next save).
      outcomes.each do |tag, pairs|
        Parse::BatchOperation.apply_save_outcome(objects[tag], pairs)
      end
    end
    batch
  end #save!
end

module Parse
  class BatchOperation
    # @!visibility private
    # The session token named by a `session:` argument, or nil when none was
    # given. A blank token is refused rather than treated as "no session".
    # @param session [String, #session_token, nil]
    # @return [String, nil]
    # @raise ArgumentError for a blank or unusable session.
    def self.session_token_for!(session)
      return nil if session.nil?
      token = session.respond_to?(:session_token) ? session.session_token : session
      unless token.is_a?(String) && !token.strip.empty?
        raise ArgumentError, "session: must be a session token or a user with one"
      end
      token
    end

    # @!visibility private
    # Apply the batch responses for one object's requests to that object.
    # @param obj [Parse::Object] the object that was saved.
    # @param pairs [Array<Array(Parse::Request, Parse::Response)>] its
    #   requests and their responses.
    def self.apply_save_outcome(obj, pairs)
      return unless obj.is_a?(Parse::Object)
      ok, failed = pairs.partition { |_req, res| res.respond_to?(:success?) && res.success? }

      ok.each do |_req, res|
        result = res.result
        next unless result.is_a?(Hash)
        if obj.id.blank? && result[Parse::Model::OBJECT_ID].present?
          obj.instance_variable_set(:@id, result[Parse::Model::OBJECT_ID])
        end
        created = result["createdAt"]
        updated = result["updatedAt"] || created
        obj.instance_variable_set(:@created_at, Parse::Date.parse(created)) if created
        obj.instance_variable_set(:@updated_at, Parse::Date.parse(updated)) if updated
        # beforeSave triggers can change saved fields; apply what came back.
        obj.set_attributes!(result)
      end
      return if ok.empty?

      if failed.empty?
        obj.changes_applied!
        # Settle array proxies explicitly as well: their dirty state lives on
        # the proxy, and a proxy left dirty resends the whole array on the
        # next save.
        settle_collections(obj, obj.class.fields(:array).keys)
      else
        clear_written_fields(obj, ok.map(&:first), failed.map(&:first))
      end
    end

    # @!visibility private
    # Clear dirty tracking only for the fields written by successful
    # requests that no failed request also touched.
    def self.clear_written_fields(obj, ok_requests, failed_requests)
      remote = ->(reqs) { reqs.flat_map { |r| r.body.is_a?(Hash) ? r.body.keys.map(&:to_s) : [] } }
      written = remote.call(ok_requests) - remote.call(failed_requests)
      return if written.empty?
      field_map = obj.class.respond_to?(:field_map) ? obj.class.field_map : {}
      local = written.map do |key|
        (field_map.find { |_local, rem| rem.to_s == key }&.first || key).to_s
      end
      settle_collections(obj, local)
      obj.clear_attribute_changes(local) if obj.respond_to?(:clear_attribute_changes)
    end

    # @!visibility private
    # Mark the collection proxies behind the named fields as saved.
    def self.settle_collections(obj, names)
      names.each do |name|
        next unless obj.respond_to?(name)
        value = obj.send(name)
        value.changes_applied! if value.is_a?(Parse::CollectionProxy) && value.respond_to?(:changes_applied!)
      end
    end
  end
end
