Dandelion::App.helpers do
  def search(klass, scope, query, number = nil)
    return klass.none if query.blank?
    return klass.none if query.length < 3 || query.length > 200

    if Padrino.env == :development
      klass.or(klass.admin_fields.map { |k, v| { k => /#{Regexp.escape(query)}/i } if v == :text || (v.is_a?(Hash) && v[:type] == :text) }.compact)
    else

      query = query.strip

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
        { '$match': scope.selector }
      ]

      results = search_with_retry(klass, pipeline, number)

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

  def search_with_retry(klass, pipeline, number, max_retries = 3)
    retries = 0
    
    begin
      results = klass.collection.aggregate(pipeline)
      results = results.first(number) if number
      results
    rescue Mongo::Error::OperationFailure => e
      retries += 1
      
      if retries <= max_retries && (e.message.include?('HostUnreachable') || e.message.include?('Connection reset'))
        sleep_time = 2 ** (retries - 1)
        logger.warn "MongoDB connection failed (attempt #{retries}/#{max_retries}), retrying in #{sleep_time}s: #{e.message}"
        sleep(sleep_time)
        retry
      else
        logger.error "MongoDB search failed after #{retries} attempts: #{e.message}"
        []
      end
    rescue => e
      logger.error "Unexpected error during MongoDB search: #{e.message}"
      []
    end
  end
end
