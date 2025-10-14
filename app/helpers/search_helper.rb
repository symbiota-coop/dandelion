Dandelion::App.helpers do
  def search(klass, scope, query, number = nil)
    return klass.none if query.blank?
    return klass.none if query.length < 3 || query.length > 200

    if Padrino.env == :development
      scope.where('$or' => klass.search_fields.map { |field| { field => /#{Regexp.escape(query)}/i } })
    else

      query = query.strip

      # Parse scope selector to extract conditions that can be handled by Atlas Search
      selector = scope.selector
      search_filters = []
      remaining_selector = {}

      selector.each do |field, value|
        # Skip top-level MongoDB operators like $or, $and, etc.
        if field.to_s.start_with?('$')
          remaining_selector[field] = value
        elsif value.is_a?(Hash)
          # Handle range operators ($gt, $gte, $lt, $lte)
          range_filter = nil
          value.each do |operator, operand|
            case operator.to_s
            when '$gt', '$gte', '$lt', '$lte'
              range_filter ||= { range: { path: field.to_s } }
              range_key = operator.to_s.delete_prefix('$')
              range_filter[:range][range_key.to_sym] = operand
            else
              # Unsupported operator, move entire field to remaining_selector
              remaining_selector[field] = value
              range_filter = nil
              break
            end
          end
          search_filters << range_filter if range_filter
        else
          # Simple equality
          search_filters << { equals: { path: field.to_s, value: value } }
        end
      end

      pipeline = [
        {
          '$search': {
            index: klass.to_s.underscore.pluralize,
            compound: {
              should: [
                { phrase: { query: query, path: { wildcard: '*' }, score: { boost: { value: 1.5 } } } },
                { text: { query: query, path: { wildcard: '*' } } }
              ],
              filter: search_filters
            }
          }
        },
        { '$addFields': { score: { '$meta': 'searchScore' } } }
      ]

      # Only add $match stage if there are remaining complex conditions
      pipeline << { '$match': remaining_selector } if remaining_selector.any?

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
