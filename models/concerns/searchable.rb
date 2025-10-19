module Searchable
  extend ActiveSupport::Concern

  class_methods do
    def search(query, scope = all, limit: nil, build_records: false, phrase_boost: 1, include_text_search: false)
      return none if query.blank?
      return none if query.length < 3 || query.length > 200

      # If query is an email address and model has an email field, search only email
      return scope.and(email: query) if query.match?(EMAIL_REGEX) && fields.key?('email')

      if Padrino.env == :development
        results = scope.where('$or' => search_fields.map { |field| { field => /#{Regexp.escape(query)}/i } })
        results = results.limit(limit) if limit
        results
      else
        query = query.strip

        search_filters = []
        remaining_selector = {}
        # Parse scope selector to extract conditions that can be handled by Atlas Search
        selector = scope.selector

        selector.each do |field, value|
          # Skip top-level MongoDB operators like $or, $and, etc.
          if field.to_s.start_with?('$')
            remaining_selector[field] = value
          # Skip null checks - Atlas Search equals filter doesn't handle null properly
          # Move them to $match stage instead where MongoDB can properly distinguish
          # between missing fields and fields explicitly set to null
          elsif value.nil?
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
            
            # Validate range filter to ensure lower bounds are not greater than upper bounds
            if range_filter
              range_values = range_filter[:range]
              lower_bound = range_values[:gt] || range_values[:gte]
              upper_bound = range_values[:lt] || range_values[:lte]
              
              # If both bounds exist and lower bound is greater than or equal to upper bound, 
              # skip this filter to avoid MongoDB error
              if lower_bound && upper_bound && lower_bound >= upper_bound
                remaining_selector[field] = value
              else
                search_filters << range_filter
              end
            end
          else
            # Simple equality
            search_filters << { equals: { path: field.to_s, value: value } }
          end
        end

        should_clauses = [
          { phrase: { query: query, path: { wildcard: '*' }, score: { boost: { value: phrase_boost } } } }
        ]
        should_clauses << { text: { query: query, path: { wildcard: '*' } } } if include_text_search

        pipeline = [
          {
            '$search': {
              index: to_s.underscore.pluralize,
              compound: {
                should: should_clauses,
                filter: search_filters,
                minimumShouldMatch: 1
              }
            }
          },
          { '$addFields': { score: { '$meta': 'searchScore' } } }
        ]

        # Only add $match stage if there are remaining complex conditions
        pipeline << { '$match': remaining_selector } if remaining_selector.any?
        pipeline << { '$limit': limit } if limit
        pipeline << { '$project': { _id: 1 } } unless build_records

        results = collection.aggregate(pipeline)

        if build_records
          results.map do |hash|
            new(hash.select { |k, _v| fields.keys.include?(k.to_s) })
          end
        else
          results.map { |doc| { id: doc[:_id] } }
        end
      end
    end

    def search_fields
      raise NotImplementedError, "#{self} must implement search_fields class method"
    end
  end
end
