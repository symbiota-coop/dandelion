# MongoDB Connection Resilience Module
# This module provides connection retry logic and error handling for MongoDB operations
# to handle SSL connection issues and network interruptions

module MongodbConnectionResilience
  def self.with_retry(max_retries: 3, backoff_base: 2, &block)
    retries = 0
    
    begin
      yield
    rescue Mongo::Error::SocketError, Mongo::Error::SocketTimeoutError, OpenSSL::SSL::SSLError => e
      retries += 1
      
      if retries <= max_retries
        sleep_time = backoff_base ** (retries - 1)
        
        # Log the retry attempt
        if defined?(Rails) && Rails.logger
          Rails.logger.warn("MongoDB connection error (attempt #{retries}/#{max_retries}): #{e.class} - #{e.message}. Retrying in #{sleep_time} seconds...")
        elsif defined?(Padrino) && Padrino.logger
          Padrino.logger.warn("MongoDB connection error (attempt #{retries}/#{max_retries}): #{e.class} - #{e.message}. Retrying in #{sleep_time} seconds...")
        end
        
        sleep(sleep_time)
        retry
      else
        # If all retries exhausted, re-raise with context
        if defined?(Honeybadger)
          Honeybadger.notify(e, context: {
            retries_exhausted: true,
            max_retries: max_retries,
            error_class: e.class.name,
            error_message: e.message
          })
        end
        
        raise e
      end
    rescue => e
      # For other types of errors, don't retry but still notify
      if defined?(Honeybadger)
        Honeybadger.notify(e, context: { mongodb_operation: true })
      end
      
      raise e
    end
  end
end

# Monkey patch Account model to add retry logic to problematic methods
if defined?(Account)
  Account.class_eval do
    alias_method :original_network, :network
    alias_method :original_network_notifications, :network_notifications

    def network
      MongodbConnectionResilience.with_retry do
        original_network
      end
    end

    def network_notifications
      MongodbConnectionResilience.with_retry do
        original_network_notifications
      end
    end
  end
end