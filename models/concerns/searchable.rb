module Searchable
  extend ActiveSupport::Concern

  # Hard cap on vector-enhanced search; beyond this we run text-only Atlas Search instead.
  VECTOR_EMBEDDING_TIMEOUT_SECONDS = 1.0
  VECTOR_AGGREGATE_MAX_TIME_MS = 1_000
  # The field holding OpenRouter embeddings (see OpenRouter::EMBEDDING_DEFAULTS) and the Atlas Vector Search index on it
  EMBEDDING_FIELD = 'voyage_embedding'.freeze
  VECTOR_INDEX = 'voyage_vector_index'.freeze
  # Atlas Search (mongot) timeout. Distinct from MongoDB MaxTimeMSExpired (code 50).
  MONGOT_TIMEOUT_CODE = 65_160

  APOSTROPHES = %w[' ’ ‘ ʼ ＇ ′ ´].freeze
  APOSTROPHE_VARIANTS = Regexp.union(APOSTROPHES)
  APOSTROPHE_CHAR_CLASS = "[#{APOSTROPHES.map { |ch| Regexp.escape(ch) }.join}]".freeze
  RANGE_OPERATORS = %w[$gt $gte $lt $lte].freeze
  # most_words: the query's words count if they have this many letters or more (or, when none do, the longest count).
  # Shorter ones only score: "the" is in most records, and as the start of a word matches "Theresa" too
  COUNTED_WORD_LENGTH = 4
  # most_words: the share of the counted words that must match, rounded up (all of 1 or 2, 2 of 3, 3 of 4, 4 of 6...),
  # like Elasticsearch's minimum_should_match, so a typo in a longer query doesn't empty the list
  REQUIRED_WORDS_SHARE = 2/3r
  # most_words: words this long or longer may match one letter out; a shorter word is one letter from too many others
  FUZZY_WORD_LENGTH = 5
  # most_words: a word as Atlas's standard analyzer splits them, on anything but letters, digits and apostrophes (so
  # "circle,trees" is two words), starting and ending with a letter or digit ('trees' is trees)
  SEARCH_WORD = /[[:alnum:]](?:(?:[[:alnum:]]|#{APOSTROPHE_CHAR_CLASS})*[[:alnum:]])?/

  class_methods do
    def search(query, scope = all, child_scope: nil, limit: nil, build_records: false, phrase_boost: 1, fuzzy_text: false, autocomplete: autocomplete_fields, vector_weight: nil, query_vector: nil, regex_search: Padrino.env != :production, pipeline_metadata: nil, emails: false, most_words: false)
      return none if query.blank?
      return none if query.length < 3 || query.length > 200

      # If child_scope is provided, filter scope to only include records that have IDs in that relationship
      # Derives the foreign key field name from the model (e.g., Account -> :account_id)
      if child_scope
        foreign_key = :"#{to_s.underscore}_id"
        scope = scope.and(:id.in => child_scope.pluck(foreign_key))
      end

      # Email is searched only for callers whose viewer can see the emails (emails: true), so that an email, or fragments
      # of one, can't find whose it is. Without it an email finds nothing, rather than those whose name or username its
      # first word starts (autocomplete), which would point a guessed email at its owner
      searched_fields = emails ? search_fields : search_fields - %w[email]
      return emails ? scope.and(email: query) : none if search_fields.include?('email') && query.match?(EMAIL_REGEX)

      # most_words: most of the query's words that count (significant_words) must match (required_word_count), each in
      # any searched field or as the start of a word in an autocomplete field, so "circle of trees" doesn't find all that
      # "of", or "circle" alone, would, while a typo in a longer query doesn't empty the list
      words = most_words ? significant_words(query) : []

      if regex_search
        results = if words.any?
                    regex_word_search(scope, words, searched_fields)
                  else
                    scope.and('$or': searched_fields.map { |field| { field => search_regex(query) } })
                  end
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
          # Leave them to the $match stage instead (else below), where MongoDB can properly distinguish
          # between missing fields and fields explicitly set to null
          elsif !value.nil? && (search_filter = atlas_search_leaf_filter(field, value))
            search_filters << search_filter
            if (vector_filter = vector_search_leaf_filter(field, value))
              search_filters_vector << vector_filter
            end
          else
            remaining_selector[field] = value
          end
        end

        should_clauses = query_variants.map do |variant|
          { phrase: { query: variant, path: searched_fields, score: { boost: { value: phrase_boost } } } }
        end
        if fuzzy_text
          should_clauses.concat(query_variants.map do |variant|
            { text: { query: variant, path: searched_fields, fuzzy: { maxEdits: 2, prefixLength: 2 } } }
          end)
        end
        # autocomplete (autocomplete_fields unless given): fields the model's Atlas Search index also maps as autocomplete
        # (edge n-grams), so the start of a word in any of them matches ("Alek" finds Aleksandra), with a clause each as
        # the operator takes one path. Not fuzzy: that scored near misses ("Alesya" for "Aleks") as high as real prefixes
        Array(autocomplete).each do |path|
          should_clauses.concat(query_variants.map do |variant|
            { autocomplete: { query: variant, path: path } }
          end)
        end

        # Atlas $search compound spec (passed as the stage body for $search). With words to match the should clauses
        # only score: the words decide what matches
        compound = { should: should_clauses, filter: search_filters, minimumShouldMatch: words.any? ? 0 : 1 }
        if words.any?
          word_clauses = words.map { |word| word_clause(word, searched_fields, autocomplete, fuzzy_text) }
          compound[:must] = [{ compound: { should: word_clauses, minimumShouldMatch: required_word_count(words.length) } }]
        end
        search_spec = { index: to_s.underscore.pluralize, compound: compound }

        text_stages = [
          { '$search': search_spec },
          { '$addFields': { score: { '$meta': 'searchScore' } } }
        ]

        suffix_stages = []
        suffix_stages << { '$match': remaining_selector } if remaining_selector.any?
        suffix_stages << { '$limit': limit } if limit
        suffix_stages << { '$unset' => [EMBEDDING_FIELD] } if build_records && fields.key?(EMBEDDING_FIELD)
        suffix_stages << { '$project': { _id: 1 } } unless build_records

        # Vector search when asked for and the model has embeddings, with the query's embedding unless given one
        # (query_vector: /stats/atlas searches with a stored event's)
        if vector_weight && vector_weight > 0 && fields.key?(EMBEDDING_FIELD)
          query_vector ||= begin
            OpenRouter.embedding(query, input_type: 'search_query', timeout: VECTOR_EMBEDDING_TIMEOUT_SECONDS)
          rescue StandardError
            nil
          end
        else
          query_vector = nil
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
              index: VECTOR_INDEX,
              path: EMBEDDING_FIELD,
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
                raise unless atlas_search_timeout?(e)

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
          # instantiate (not new) so the records count as saved, like a query's, and their associations query the database
          results.map do |hash|
            instantiate(hash.select { |k, _v| fields.keys.include?(k.to_s) })
          end
        else
          results.map { |doc| { id: doc[:_id] } }
        end
      end
    end

    def search_fields
      raise NotImplementedError, "#{self} must implement search_fields class method"
    end

    # Fields the model's Atlas Search index also maps as autocomplete, which searches then match by the start of a word
    # (search's autocomplete:). None unless the model names them
    def autocomplete_fields
      []
    end

    def atlas_search_timeout?(error)
      error.max_time_ms_expired? || error.code == MONGOT_TIMEOUT_CODE
    end

    def search_regex(text)
      /#{Regexp.escape(text).gsub(APOSTROPHE_VARIANTS, APOSTROPHE_CHAR_CLASS)}/i
    end

    def word_start_regex(word)
      /(?<![[:alnum:]])#{search_regex(word).source}/i
    end

    def significant_words(query)
      words = query.scan(SEARCH_WORD).uniq(&:downcase)
      length = ->(word) { word.scan(/[[:alnum:]]/).length }
      counted_length = [COUNTED_WORD_LENGTH, words.map(&length).max.to_i].min
      words.select { |word| length.(word) >= counted_length }
    end

    def required_word_count(word_count)
      (word_count * REQUIRED_WORDS_SHARE).ceil
    end

    # The regex search's version of the Atlas one: records with any of the words, then those with enough of them, each
    # word matching at the start of a word, as Atlas's whole words and autocomplete's word starts do ("bath" isn't in
    # "Sabbath")
    def regex_word_search(scope, words, fields)
      regexes = words.map { |word| word_start_regex(word) }
      candidates = scope.and('$or': regexes.flat_map { |regex| fields.map { |field| { field => regex } } })
      ids = candidates.pluck(:id, *fields).filter_map do |id, *values|
        text = values.flatten.compact.join(' ')
        id if regexes.count { |regex| text.match?(regex) } >= required_word_count(words.length)
      end
      scope.and(:id.in => ids)
    end

    # A word matches if any searched field has it (fuzzily, if fuzzy and the word is long enough), or an autocomplete
    # field has a word it starts
    def word_clause(word, paths, autocomplete, fuzzy)
      alternatives = apostrophe_variants(word).flat_map do |variant|
        text = { query: variant, path: paths }
        text[:fuzzy] = { maxEdits: 1, prefixLength: 2 } if fuzzy && word.length >= FUZZY_WORD_LENGTH
        [{ text: text }] + Array(autocomplete).map { |path| { autocomplete: { query: variant, path: path } } }
      end
      { compound: { should: alternatives, minimumShouldMatch: 1 } }
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
