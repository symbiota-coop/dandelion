module Searchable
  extend ActiveSupport::Concern

  APOSTROPHE_VARIANTS = /['’]/

  class_methods do
    def search(query, scope = all, child_scope: nil, limit: nil, build_records: false, phrase_boost: 1, text_search: false, vector_weight: nil, regex_search: Padrino.env != :production)
      return none if query.blank?
      return none if query.length < 3 || query.length > 200

      # If child_scope is provided, filter scope to only include records that have IDs in that relationship
      # Derives the foreign key field name from the model (e.g., Account -> :account_id)
      if child_scope
        foreign_key = :"#{to_s.underscore}_id"
        scope = scope.and(:id.in => child_scope.pluck(foreign_key))
      end

      # If query is an email address and model has an email field, search only email
      return scope.and(email: query) if query.match?(EMAIL_REGEX) && fields.key?('email')

      if regex_search
        pattern = Regexp.escape(query).gsub(APOSTROPHE_VARIANTS, "[’']")
        results = scope.where('$or': search_fields.map { |field| { field => /#{pattern}/i } })
        results = results.limit(limit) if limit
        results
      else
        query = query.strip
        query_variants = apostrophe_variants(query)

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

        should_clauses = query_variants.map do |variant|
          { phrase: { query: variant, path: { wildcard: '*' }, score: { boost: { value: phrase_boost } } } }
        end
        if text_search
          should_clauses.concat(query_variants.map do |variant|
            { text: { query: variant, path: { wildcard: '*' }, fuzzy: { maxEdits: 2, prefixLength: 2 } } }
          end)
        end

        # Build text search stage (used in both vector+text and text-only searches)
        text_search_stage = {
          index: to_s.underscore.pluralize,
          compound: {
            should: should_clauses,
            filter: search_filters,
            minimumShouldMatch: 1
          }
        }

        # Try to get embedding for vector search if enabled and model has embedding field
        query_vector = nil
        if vector_weight && vector_weight > 0 && fields.key?('embedding')
          query_vector = begin
            OpenRouter.embedding(query)
          rescue StandardError
            nil
          end
        end

        if query_vector
          # Use $rankFusion to combine vector and text search
          fetch_limit = limit ? limit * 2 : 100
          num_candidates = 20 * fetch_limit

          vector_search_stage = {
            index: 'vector_index',
            path: 'embedding',
            queryVector: query_vector,
            numCandidates: num_candidates,
            limit: fetch_limit
          }

          pipeline = [
            {
              '$rankFusion': {
                input: {
                  pipelines: {
                    vectorPipeline: [
                      { '$vectorSearch': vector_search_stage }
                    ],
                    textPipeline: [
                      { '$search': text_search_stage },
                      { '$limit': fetch_limit }
                    ]
                  }
                },
                combination: {
                  weights: {
                    vectorPipeline: vector_weight,
                    textPipeline: 1 - vector_weight
                  }
                }
              }
            }
          ]
        else
          # Fall back to text-only search
          pipeline = [
            { '$search': text_search_stage },
            { '$addFields': { score: { '$meta': 'searchScore' } } }
          ]
        end

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

    def apostrophe_variants(query)
      return [query] unless query.match?(APOSTROPHE_VARIANTS)

      [
        query,
        query.gsub(APOSTROPHE_VARIANTS, "'"),
        query.gsub(APOSTROPHE_VARIANTS, '’')
      ].uniq
    end
  end
end
