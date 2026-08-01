# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module Cache
    # The derived half of Moneta's store interface.
    #
    # Moneta gets these from `Moneta::Defaults`, which the SDK's own store
    # wrappers do not include. That gap was invisible for a long time because
    # the Faraday caching middleware only ever calls the primitives. It is not
    # invisible to applications: the README has documented
    # `Parse.cache["key"] = value` and `Parse.cache.fetch(...)` for years, and
    # neither existed on {Parse::Cache::Redis}. Anyone following the
    # documentation got `NoMethodError`.
    #
    # **Required primitives.** An including class must implement `load`,
    # `store`, `delete`, and `key?`, each taking Moneta's options argument.
    # `load` is the read primitive, NOT `[]`: an earlier version of this
    # module derived `load` from `[]` and consulted a `moneta_backing_store`
    # that defaulted to `self`, so `load(key, expires: 60)` asked whether self
    # responded to the method it was already executing and recursed until
    # `SystemStackError`. Every option-carrying read went the same way, since
    # `fetch`, `values_at`, `slice`, and `fetch_values` all route through it.
    # A wrapper knows how to reach its own backing store; this module does
    # not, and should not guess.
    #
    # Optional capabilities that cannot be derived (`create`, `increment`,
    # `decrement`, `expire`) are deliberately absent: they need backend
    # support, and claiming them unconditionally would turn a feature check
    # into a runtime error. Feature-detect those with `respond_to?`.
    module MonetaSurface
      # @param key [String]
      # @return [Object, nil]
      def [](key)
        load(key, {})
      end

      # @param key [String]
      # @param value [Object]
      # @return [Object] the stored value, so assignment chains as Ruby
      #   expects.
      def []=(key, value)
        store(key, value, {})
        value
      end

      # Copied from `Moneta::Defaults#fetch`, deliberately line for line.
      #
      # Its two shapes read the second positional differently: without a block
      # it is the default value, with one it is the OPTIONS hash and the block
      # supplies the fallback. Passing both a block and a third argument is an
      # error, not something to silently absorb.
      #
      # This has now been wrong twice from interpretation: first treating the
      # second argument as a default in both shapes, which dropped the
      # options, then accepting a block alongside a third argument and
      # ignoring one of the two hashes. Reproducing the upstream method is
      # cheaper than continuing to infer it.
      #
      # @param key [String]
      # @param default [Object] the fallback without a block, the options with
      #   one.
      # @param options [Hash, nil]
      # @raise [ArgumentError] when given both a block and `options`.
      # @return [Object]
      def fetch(key, default = nil, options = nil)
        if block_given?
          raise ArgumentError, "Only one argument accepted if block is given" if options
          result = load(key, default || {})
          result == nil ? yield(key) : result
        else
          result = load(key, options || {})
          result == nil ? default : result
        end
      end

      # @param keys [Array<String>]
      # @return [Array<Object, nil>] values in the order requested, nil for
      #   misses.
      def values_at(*keys, **options)
        keys.map { |key| load(key, options) }
      end

      # @param keys [Array<String>]
      # @return [Array<Object>] values in the order requested, with the block
      #   result substituted for misses.
      def fetch_values(*keys, **options)
        values = values_at(*keys, **options)
        return values unless block_given?
        keys.zip(values).map do |key, value|
          value == nil ? yield(key) : value
        end
      end

      # @param keys [Array<String>]
      # @return [Array<Array(String, Object)>] `[key, value]` pairs for the
      #   present keys only. Pairs rather than a Hash because that is what
      #   Moneta returns, and the point of this module is to behave the way a
      #   Moneta store does, not the way a Hash does.
      def slice(*keys, **options)
        keys.each_with_object([]) do |key, out|
          value = load(key, options)
          out << [key, value] unless value.nil?
        end
      end

      # @param pairs [Hash, Enumerable] key/value pairs to write.
      # @return [self] matching Moneta, which returns the store.
      def merge!(pairs, options = {})
        pairs.each do |key, value|
          if block_given?
            # The existing value is read with the SAME options the write will
            # use, so a conflict block never decides against a value fetched
            # under different terms than the one being stored.
            existing = load(key, options)
            value = yield(key, existing, value) unless existing.nil?
          end
          store(key, value, options)
        end
        self
      end

      alias_method :update, :merge!
    end
  end
end
