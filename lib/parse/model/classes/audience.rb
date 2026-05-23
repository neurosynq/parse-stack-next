# encoding: UTF-8
# frozen_string_literal: true

# Note: Do not require "../object" here - this file is loaded from object.rb
# and adding that require would create a circular dependency.

module Parse
  # This class represents the data and columns contained in the standard Parse
  # `_Audience` collection. Audiences are pre-defined groups of installations
  # that can be targeted for push notifications. They store query constraints
  # that define which installations belong to the audience.
  #
  # Audiences are useful for:
  # - Reusable push targets (e.g., "VIP Users", "Beta Testers")
  # - A/B testing different user segments
  # - Marketing campaigns to specific demographics
  #
  # == Caching
  #
  # Audience queries are cached by default to improve push notification performance.
  # The cache has a configurable TTL (default: 5 minutes).
  #
  # @example Configure cache TTL
  #   Parse::Audience.cache_ttl = 600  # 10 minutes
  #
  # @example Clear the cache
  #   Parse::Audience.clear_cache!
  #
  # @example Bypass cache for a specific lookup
  #   audience = Parse::Audience.find_by_name("VIP Users", cache: false)
  #
  # The default schema for the {Audience} class is as follows:
  #   class Parse::Audience < Parse::Object
  #      # See Parse::Object for inherited properties...
  #
  #      property :name
  #      property :query, :object  # The Installation query constraints
  #   end
  #
  # @example Creating an audience
  #   audience = Parse::Audience.new(
  #     name: "iOS VIP Users",
  #     query: { "deviceType" => "ios", "vip" => true }
  #   )
  #   audience.save
  #
  # @example Targeting an audience with push
  #   Parse::Push.new
  #     .to_audience("iOS VIP Users")
  #     .with_alert("Exclusive offer!")
  #     .send!
  #
  # @see Parse::Push#to_audience
  # @see Parse::Object
  class Audience < Parse::Object
    parse_class Parse::Model::CLASS_AUDIENCE

    # Default cache TTL in seconds (5 minutes)
    DEFAULT_CACHE_TTL = 300

    class << self
      # @return [Integer] the cache TTL in seconds (default: 300)
      attr_writer :cache_ttl

      def cache_ttl
        @cache_ttl ||= DEFAULT_CACHE_TTL
      end

      # Clear the audience cache
      # @return [void]
      def clear_cache!
        cache_mutex.synchronize do
          @audience_cache = {}
          @cache_timestamps = {}
        end
      end

      # Get an audience from cache or fetch from server
      # @param name [String] the audience name
      # @param cache [Boolean] whether to use cache (default: true)
      # @return [Parse::Audience, nil] the audience or nil if not found
      def cache_fetch(name, cache: true)
        return find_by_name_uncached(name) unless cache

        cache_mutex.synchronize do
          @audience_cache ||= {}
          @cache_timestamps ||= {}

          # Cleanup expired entries periodically to prevent memory growth
          cleanup_expired_cache_entries

          cached = @audience_cache[name]
          timestamp = @cache_timestamps[name]

          # Check if cache is valid
          if timestamp && (Time.now.to_i - timestamp) < cache_ttl
            return cached
          end

          # Fetch and cache (fetch happens inside lock - acceptable for short TTL cache)
          audience = find_by_name_uncached(name)
          @audience_cache[name] = audience
          @cache_timestamps[name] = Time.now.to_i

          audience
        end
      end

      # Remove expired entries from cache to prevent memory leaks
      # Called automatically during cache_fetch, but can also be called manually
      # @return [Integer] number of entries removed
      def cleanup_expired_cache!
        cache_mutex.synchronize do
          cleanup_expired_cache_entries
        end
      end

      # Thread-safe mutex for cache operations
      # @return [Mutex]
      def cache_mutex
        @cache_mutex ||= Mutex.new
      end

      private

      # Internal method to cleanup expired cache entries (must be called within synchronize block)
      # @return [Integer] number of entries removed
      def cleanup_expired_cache_entries
        return 0 unless @cache_timestamps

        now = Time.now.to_i
        expired_keys = @cache_timestamps.select { |_key, ts| now - ts >= cache_ttl }.keys

        expired_keys.each do |key|
          @audience_cache&.delete(key)
          @cache_timestamps.delete(key)
        end

        expired_keys.size
      end

      def find_by_name_uncached(name)
        first(name: name)
      end
    end

    # @!attribute name
    # The display name of this audience.
    # @return [String] The audience name.
    property :name

    # @!attribute query
    # The query constraints that define which installations belong to this audience.
    # This is stored as a hash matching the Installation query format.
    # @return [Hash] The query constraint hash.
    # @example
    #   audience.query = { "deviceType" => "ios", "appVersion" => { "$gte" => "2.0" } }
    property :query, :object

    # Alias for query to match Parse Server naming conventions.
    # @return [Hash] The query constraint hash.
    def query_constraint
      query
    end

    # Set the query constraint.
    # @param constraints [Hash] The query constraint hash.
    def query_constraint=(constraints)
      self.query = constraints
    end

    class << self
      # Find an audience by name (uses cache by default).
      # @param name [String] the audience name
      # @param cache [Boolean] whether to use cache (default: true)
      # @return [Parse::Audience, nil] the audience or nil if not found
      # @example
      #   audience = Parse::Audience.find_by_name("VIP Users")
      #   audience = Parse::Audience.find_by_name("VIP Users", cache: false)  # Bypass cache
      def find_by_name(name, cache: true)
        cache_fetch(name, cache: cache)
      end

      # Get the count of installations matching an audience's query.
      # @param audience_name [String] the audience name
      # @return [Integer] the count of matching installations
      # @example
      #   count = Parse::Audience.installation_count("VIP Users")
      def installation_count(audience_name)
        audience = find_by_name(audience_name)
        return 0 unless audience && audience.query.present?

        q = Parse::Installation.query
        audience.query.each do |key, value|
          q.where(key.to_sym => value)
        end
        q.count
      end

      # Get a query for installations matching an audience.
      # @param audience_name [String] the audience name
      # @return [Parse::Query] a query for matching installations
      # @example
      #   installations = Parse::Audience.installations("VIP Users").all
      def installations(audience_name)
        audience = find_by_name(audience_name)
        q = Parse::Installation.query
        if audience && audience.query.present?
          audience.query.each do |key, value|
            q.where(key.to_sym => value)
          end
        end
        q
      end
    end

    # Get the count of installations matching this audience's query.
    # @return [Integer] the count of matching installations
    # @example
    #   audience = Parse::Audience.first
    #   puts "#{audience.name} has #{audience.installation_count} members"
    def installation_count
      return 0 unless query.present?

      q = Parse::Installation.query
      query.each do |key, value|
        q.where(key.to_sym => value)
      end
      q.count
    end

    # Get a query for installations matching this audience.
    # @return [Parse::Query] a query for matching installations
    # @example
    #   audience.installations.each { |i| puts i.device_token }
    def installations
      q = Parse::Installation.query
      if query.present?
        query.each do |key, value|
          q.where(key.to_sym => value)
        end
      end
      q
    end
  end
end
