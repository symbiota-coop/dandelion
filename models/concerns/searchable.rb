module Searchable
  extend ActiveSupport::Concern

  # Hard cap on vector-enhanced search; beyond this we run text-only Atlas Search instead.
  VECTOR_EMBEDDING_TIMEOUT_SECONDS = 1.0
  VECTOR_AGGREGATE_MAX_TIME_MS = 1_000

  APOSTROPHES = %w[' ’ ‘ ʼ ＇ ′ ´].freeze
  APOSTROPHE_VARIANTS = Regexp.union(APOSTROPHES)
  APOSTROPHE_CHAR_CLASS = "[#{APOSTROPHES.map { |ch| Regexp.escape(ch) }.join}]".freeze
  RANGE_OPERATORS = %w[$gt $gte $lt $lte].freeze

  class_methods do
    def search(query, scope = all, child_scope: nil, limit: nil, build_records: false, phrase_boost: 1, fuzzy_text: false, vector_weight: nil, regex_search: Padrino.env != :production, pipeline_metadata: nil)
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
        pattern = Regexp.escape(query).gsub(APOSTROPHE_VARIANTS, APOSTROPHE_CHAR_CLASS)
        results = scope.and('$or': search_fields.map { |field| { field => /#{pattern}/i } })
        results = results.limit(limit) if limit
        results
      else
        query = query.strip
        query_variants = apostrophe_variants(query)

        search_filters = []
        search_filters_vector = []
        remaining_selector = {}
        # Parse scope selector to extract conditions that can be handled by Atlas Search
        selector = scope.selector

        selector.each do |field, value|
          # Push simple boolean combinations into Atlas Search when every branch has
          # equivalent Search semantics. Unsupported branches remain in $match.
          if field.to_s.start_with?('$')
            search_filter = atlas_search_filter_for_selector({ field => value }) unless vector_weight&.positive?
            if search_filter
              search_filters << search_filter
            else
              remaining_selector[field] = value
            end
          # Skip null checks - Atlas Search equals filter doesn't handle null properly
          # Move them to $match stage instead where MongoDB can properly distinguish
          # between missing fields and fields explicitly set to null
          elsif value.nil?
            remaining_selector[field] = value
          elsif (search_filter = atlas_search_leaf_filter(field, value))
            search_filters << search_filter
            if (vector_filter = vector_search_leaf_filter(field, value))
              search_filters_vector << vector_filter
            end
          else
            remaining_selector[field] = value
          end
        end

        should_clauses = query_variants.map do |variant|
          { phrase: { query: variant, path: search_fields, score: { boost: { value: phrase_boost } } } }
        end
        if fuzzy_text
          should_clauses.concat(query_variants.map do |variant|
            { text: { query: variant, path: search_fields, fuzzy: { maxEdits: 2, prefixLength: 2 } } }
          end)
        end

        # Atlas $search compound spec (passed as the stage body for $search).
        search_spec = {
          index: to_s.underscore.pluralize,
          compound: {
            should: should_clauses,
            filter: search_filters,
            minimumShouldMatch: 1
          }
        }

        text_stages = [
          { '$search': search_spec },
          { '$addFields': { score: { '$meta': 'searchScore' } } }
        ]

        suffix_stages = []
        suffix_stages << { '$match': remaining_selector } if remaining_selector.any?
        suffix_stages << { '$limit': limit } if limit
        suffix_stages << { '$unset' => %w[embedding] } if build_records && fields.key?('embedding')
        suffix_stages << { '$project': { _id: 1 } } unless build_records

        # Try to get embedding for vector search if enabled and model has embedding field
        query_vector = nil
        if vector_weight && vector_weight > 0 && fields.key?('embedding')
          query_vector = begin
            OpenRouter.embedding(query, timeout: VECTOR_EMBEDDING_TIMEOUT_SECONDS)
          rescue StandardError
            nil
          end
        end

        fusion_stages =
          if query_vector
            vector_filter = if search_filters_vector.empty?
                              nil
                            elsif search_filters_vector.length == 1
                              search_filters_vector.first
                            else
                              { '$and' => search_filters_vector }
                            end

            fetch_limit = limit ? limit * 2 : 100
            num_candidates = 20 * fetch_limit

            vector_search_stage = {
              index: 'vector_index',
              path: 'embedding',
              queryVector: query_vector,
              numCandidates: num_candidates,
              limit: fetch_limit
            }
            vector_search_stage[:filter] = vector_filter if vector_filter

            [
              {
                '$rankFusion': {
                  input: {
                    pipelines: {
                      vectorPipeline: [
                        { '$vectorSearch': vector_search_stage }
                      ],
                      textPipeline: [
                        { '$search': search_spec },
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
          end

        results = Sentry.with_child_span(op: 'search.query', description: 'Atlas Search') do |span|
          span&.set_data('search.model', name)
          span&.set_data('search.limit', limit) if limit
          span&.set_data('search.build_records', build_records)
          span&.set_data('search.fuzzy_text', fuzzy_text)

          text_fallback = false
          documents =
            if fusion_stages
              begin
                collection
                  .aggregate(fusion_stages + suffix_stages, max_time_ms: VECTOR_AGGREGATE_MAX_TIME_MS)
                  .to_a
              rescue Mongo::Error::OperationFailure => e
                raise unless e.max_time_ms_expired?

                text_fallback = true
                collection.aggregate(text_stages + suffix_stages).to_a
              end
            else
              collection.aggregate(text_stages + suffix_stages).to_a
            end

          pipeline_label =
            if fusion_stages && !text_fallback
              'vector'
            elsif fusion_stages && text_fallback
              'text_fallback'
            else
              'text'
            end
          pipeline_metadata[:pipeline] = pipeline_label if pipeline_metadata
          span&.set_data('search.pipeline', pipeline_label)
          span&.set_data('search.result_count', documents.length)

          documents
        end

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

      ([query] + APOSTROPHES.map { |ch| query.gsub(APOSTROPHE_VARIANTS, ch) }).uniq
    end

    def atlas_search_filter_for_selector(selector)
      return nil unless selector.is_a?(Hash) && selector.any?

      filters = selector.map do |field, value|
        atlas_search_filter_for_selector_entry(field, value)
      end
      return nil if filters.any?(&:nil?)

      filters.length == 1 ? filters.first : { compound: { filter: filters } }
    end

    def atlas_search_filter_for_selector_entry(field, value)
      case field.to_s
      when '$and'
        atlas_search_compound_filter(value, :filter)
      when '$or'
        atlas_search_compound_filter(value, :should)
      else
        atlas_search_leaf_filter(field, value)
      end
    end

    def atlas_search_compound_filter(branches, clause)
      return nil unless branches.is_a?(Array) && branches.any?

      filters = branches.map { |branch| atlas_search_filter_for_selector(branch) }
      return nil if filters.any?(&:nil?)

      compound = { clause => filters }
      compound[:minimumShouldMatch] = 1 if clause == :should
      { compound: compound }
    end

    def atlas_search_leaf_filter(field, value)
      return nil if value.nil? || field.to_s.start_with?('$')

      if value.is_a?(Hash)
        atlas_search_range_filter(field, value)
      else
        { equals: { path: field.to_s, value: value } }
      end
    end

    def atlas_search_range_filter(field, value)
      range_values = search_range_values(value)
      return nil unless range_values

      { range: { path: field.to_s }.merge(range_values) }
    end

    def vector_search_leaf_filter(field, value)
      if value.is_a?(Hash)
        vector_search_range_filter(field, value)
      else
        { field => value }
      end
    end

    def vector_search_range_filter(field, value)
      range_values = search_range_values(value, preserve_operator_keys: true)
      return nil unless range_values

      { field => range_values }
    end

    def search_range_values(value, preserve_operator_keys: false)
      return nil if value.empty?

      range_values = {}
      normalized_range_values = {}
      value.each do |operator, operand|
        operator_name = operator.to_s
        return nil unless RANGE_OPERATORS.include?(operator_name)

        normalized_operator = operator_name.delete_prefix('$').to_sym
        normalized_range_values[normalized_operator] = operand
        range_values[preserve_operator_keys ? operator : normalized_operator] = operand
      end

      lower_bound = normalized_range_values[:gt] || normalized_range_values[:gte]
      upper_bound = normalized_range_values[:lt] || normalized_range_values[:lte]
      return nil if lower_bound && upper_bound && lower_bound >= upper_bound

      range_values
    end
  end
end
