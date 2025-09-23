Dandelion::App.helpers do
  def search(klass, match, query, number = nil)
    if Padrino.env == :development
      klass.or(klass.admin_fields.map { |k, v| { k => /#{Regexp.escape(query)}/i } if v == :text || (v.is_a?(Hash) && v[:type] == :text) }.compact)
    else
      pipeline = [
        {
          '$search': {
            index: klass.to_s.underscore.pluralize,
            compound: {
              should: [
                { phrase: { query: query, path: { wildcard: '*' }, score: { boost: { value: 1.5 } } } },
                { text: { query: query, path: { wildcard: '*' } } }
              ]
            }
          }
        },
        { '$addFields': { score: { '$meta': 'searchScore' } } },
        { '$match': match.selector }
      ]

      results = execute_with_retry do
        aggregation_results = klass.collection.aggregate(pipeline)
        number ? aggregation_results.first(number) : aggregation_results.to_a
      end

      # Return empty array if connection failed after retries
      return [] unless results

      # Filter by score threshold (50% of max score)
      if results.any?
        max_score = results.map { |doc| doc['score'] }.max
        min_score = max_score * 0.5
        results = results.select { |doc| doc['score'] >= min_score }
      end

      results.map do |hash|
        klass.new(hash.select { |k, _v| klass.fields.keys.include?(k.to_s) })
      end
    end
  end

  private

  def execute_with_retry(max_retries: 3, base_delay: 1.0)
    attempt = 0
    begin
      attempt += 1
      yield
    rescue Mongo::Error::OperationFailure, Mongo::Error::SocketError, Mongo::Error::ServerSelectionError => e
      if attempt <= max_retries && connection_error?(e)
        delay = base_delay * (2**(attempt - 1)) # Exponential backoff
        sleep(delay)
        retry
      else
        # Log the error but don't re-raise to prevent application crashes
        puts "MongoDB connection error after #{max_retries} retries: #{e.message}"
        nil
      end
    end
  end

  def connection_error?(error)
    error.message.include?('HostUnreachable') ||
      error.message.include?('Connection closed') ||
      error.message.include?('NetworkTimeout') ||
      error.message.include?('SocketError') ||
      error.message.include?('ServerSelectionError')
  end
end
