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

      results = klass.collection.aggregate(pipeline)
      results = results.first(number) if number

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
end
