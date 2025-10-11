require 'mongoid'
require 'active_support/cache'

# Minimal Mongo-backed ActiveSupport cache store for Rack::Attack
module ActiveSupport
  module Cache
    class MongoStore < Store
      DEFAULT_COLLECTION = 'cache'.freeze

      def initialize(collection = nil, options = {})
        super(options)
        @collection = collection || Mongoid.default_client[options[:collection] || DEFAULT_COLLECTION]

        # Optionally ensure TTL index for automatic expiry cleanup
        return unless options.fetch(:ensure_ttl_index, true)

        begin
          @collection.indexes.create_one({ expires_at: 1 }, expire_after_seconds: 0)
        rescue StandardError
          # Index creation failures shouldn't break the app
        end
      end

      # Public API expected by ActiveSupport/Rack::Attack
      def read(name, options = nil)
        key = normalize_key(name, options)
        doc = @collection.find(_id: key).first
        return nil unless doc
        return nil if expired?(doc)

        decode(doc)
      end

      def write(name, value, options = nil)
        options ||= {}
        key = normalize_key(name, options)
        expires_at = compute_expires_at(options)
        value_doc = encode(value)

        @collection.update_one(
          { _id: key },
          {
            '$set' => value_doc.merge('expires_at' => expires_at)
          },
          upsert: true
        )
        true
      end

      def delete(name, options = nil)
        key = normalize_key(name, options)
        @collection.delete_one(_id: key)
        true
      end

      def exist?(name, options = nil)
        key = normalize_key(name, options)
        doc = @collection.find(_id: key).projection(_id: 1, expires_at: 1).first
        !!(doc && !expired?(doc))
      end

      def increment(name, amount = 1, options = nil)
        options ||= {}
        key = normalize_key(name, options)
        expires_at = compute_expires_at(options)

        # Atomic increment for integer counters (Rack::Attack usage)
        doc = @collection.find(_id: key).find_one_and_update(
          {
            '$inc' => { 'value' => amount.to_i },
            '$set' => { 'expires_at' => expires_at, 'marshaled' => false }
          },
          upsert: true,
          return_document: :after
        )
        doc && doc['value']
      rescue StandardError
        # Fallback to non-atomic path if needed
        current = (read(name, options) || 0).to_i + amount.to_i
        write(name, current, options)
        current
      end

      def clear(_options = nil)
        @collection.delete_many({})
        true
      end

      private

      def compute_expires_at(options)
        return nil unless options && options[:expires_in]

        (Time.now.utc + options[:expires_in].to_i)
      end

      def expired?(doc)
        exp = doc['expires_at']
        exp && Time.now.utc >= exp
      end

      def encode(value)
        if value.is_a?(Integer)
          { 'value' => value, 'marshaled' => false }
        else
          { 'value' => BSON::Binary.new(Marshal.dump(value)), 'marshaled' => true }
        end
      end

      def decode(doc)
        if doc['marshaled']
          Marshal.load(doc['value'].data)
        else
          doc['value']
        end
      end
    end
  end
end
