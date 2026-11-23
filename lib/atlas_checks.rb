require_relative 'server_checks' # extended as the module is defined, before Padrino would load it

# The checks /stats/atlas runs on the features only Atlas has, which CI can't test as it runs on plain MongoDB (and dev
# and the tests search with regex): each searchable model's Atlas Search index, and searches through Searchable that use
# it, by whole word (phrase), by the start of a field (autocomplete) and with embeddings ($vectorSearch and $rankFusion),
# and that an email, or the part of one from its @, finds its account only for those who can see emails. Each search is of a real record, narrowed to it by id, so it passes only if that record comes back
module AtlasChecks
  extend ServerChecks

  # $rankFusion, which combines vector and text search, needs MongoDB 8.0
  RANK_FUSION_VERSION = Gem::Version.new('8.0')
  # A word to search for is at least this long, so the start of it searched for (AUTOCOMPLETE_PREFIX letters) isn't the
  # whole word, which a phrase would match without autocomplete
  SAMPLE_WORD = /\A\p{L}{6,}\z/
  # A token as Atlas's standard analyzer (Unicode word breaks) sees one, roughly: letters, digits and underscores, kept
  # together across an apostrophe, full stop or colon between them, so O'Sullivan is one token and Sullivan alone
  # wouldn't match it. Only tokens that are a SAMPLE_WORD are searched for
  SAMPLE_TOKEN = /[\p{L}\p{N}_]+(?:(?:#{Searchable::APOSTROPHE_CHAR_CLASS}|[.:])[\p{L}\p{N}_]+)*/
  AUTOCOMPLETE_PREFIX = 4
  # A username of two long words joined by an underscore (damp_resonance_8), which Atlas keeps one token
  USERNAME_SAMPLE = /[[:alpha:]]{#{Searchable::COUNTED_WORD_LENGTH},}_[[:alpha:]]{#{Searchable::COUNTED_WORD_LENGTH},}/
  # Records to look through for one with such a word
  SAMPLE_SIZE = 50

  class << self
    def searchable_models
      Mongoid.models.select { |model| model.include?(Searchable) }.sort_by(&:name)
    end

    def run
      [server_check] + searchable_models.flat_map { |model| model_checks(model) } + vector_checks
    end

    private

    def server_check
      check('Server', 'MongoDB version') do
        version = Mongoid.default_client.database.command(buildInfo: 1).first['version']
        ok = Gem::Version.new(version) >= RANK_FUSION_VERSION
        [ok, ok ? version : "#{version}: $rankFusion needs #{RANK_FUSION_VERSION}"]
      end
    end

    def model_checks(model)
      group = model.name
      index = nil
      checks = [check(group, 'Search index') do
        index = search_index(model, model.to_s.underscore.pluralize)
        index_state(index)
      end]
      fields = model.autocomplete_fields
      fields.each do |field|
        checks << check(group, "#{field} mapped as autocomplete") do
          raise 'no search index' unless index

          types = Array.wrap(index.dig('latestDefinition', 'mappings', 'fields', field)).map { |mapping| mapping['type'] }
          [types.include?('autocomplete') && types.include?('string'), types.any? ? types.join(', ') : 'not mapped']
        end
      end
      checks << check(group, 'Whole-word search') do
        record, word = sample(model, fields.first || model.search_fields.first)
        raise 'no record with a long enough word to search for' unless record

        found(model, record, word, autocomplete: nil)
      end
      # Each field's own clause, so one field mapped wrongly can't pass on another's match. Its first word, as the start of
      # a field is all autocomplete promises: usernames (damp_resonance_8) are one token, so later words don't match
      fields.each do |field|
        checks << check(group, "Search by the start of #{field}") do
          record, word = sample(model, field, first_word: true)
          raise "no record with a long enough word in #{field} to search for" unless record

          found(model, record, word[0, AUTOCOMPLETE_PREFIX], autocomplete: [field])
        end
      end
      # The quick search (most_words) of a whole username, which passes only if its words split as Atlas's do: at an
      # underscore, they'd be words no token matches
      if model.search_fields.include?('username')
        checks << check(group, 'Quick search by a whole username') do
          record = model.and(username: USERNAME_SAMPLE).only(:_id, :username).order('created_at desc').first
          raise 'no record with a username of two long words to search for' unless record

          found(model, record, record.username, fuzzy_text: true, most_words: true)
        end
      end
      checks += email_checks(model, group) if model.search_fields.include?('email')
      checks
    end

    # Searches leave email out unless the viewer can see emails (Searchable's emails:), so neither a recent record's email
    # nor the part of it from its @ (a fragment, which only Atlas Search would match) finds it then; for an email viewer,
    # both do, so the refusal isn't passing because the search can't match emails at all
    def email_checks(model, group)
      record = model.and(:email.nin => [nil, '']).only(:_id, :email).order('created_at desc').first
      queries = [record&.email, record&.email&.then { |email| email[email.index('@')..] }].compact
      [
        check(group, 'Email search refused to those who can\'t see emails') do
          raise 'no record with an email' unless record

          matched = queries.select { |query| model.search(query, model.and(id: record.id), regex_search: false).pluck(:id).include?(record.id) }
          [matched.empty?, matched.any? ? "found by #{matched.map { |query| %("#{query}") }.join(' and ')}" : 'the email and the part from its @']
        end,
        check(group, 'Email search for those who can see emails') do
          raise 'no record with an email' unless record

          missed = queries.reject { |query| model.search(query, model.and(id: record.id), regex_search: false, emails: true).pluck(:id).include?(record.id) }
          [missed.empty?, missed.any? ? "not found by #{missed.map { |query| %("#{query}") }.join(' and ')}" : 'the email and the part from its @']
        end
      ]
    end

    def vector_checks
      models = searchable_models.select { |model| model.fields.key?(Searchable::EMBEDDING_FIELD) }
      models.flat_map do |model|
        group = "#{model.name} embeddings"
        [
          check(group, 'Vector index') { index_state(search_index(model, Searchable::VECTOR_INDEX)) },
          check(group, 'Vector and text search combined') do
            record = model.and(Searchable::EMBEDDING_FIELD.to_sym.ne => nil).only(:_id, :name, Searchable::EMBEDDING_FIELD)
                          .order('created_at desc').first
            raise 'no record with an embedding' unless record

            # Its own embedding finds it first, and its name by text
            query = record.name.split.first(3).join(' ')
            metadata = {}
            ids = model.search(query, model.all, limit: 10, vector_weight: 0.5, query_vector: record.send(Searchable::EMBEDDING_FIELD),
                                                 regex_search: false, pipeline_metadata: metadata).pluck(:id)
            if metadata[:pipeline] != 'vector'
              [false, "ran the #{metadata[:pipeline]} pipeline, not vector"]
            else
              [ids.include?(record.id), %("#{query}")]
            end
          end
        ]
      end
    end

    def search_index(model, name)
      model.collection.search_indexes.find { |index| index['name'] == name }
    end

    def index_state(index)
      return [false, 'missing'] unless index

      [index['status'] == 'READY' && index['queryable'], [index['status'], ('not queryable' unless index['queryable'])].compact.join(', ')]
    end

    # A recent record whose field has a word long enough to search for by its start (with first_word, its first word)
    def sample(model, field, first_word: false)
      model.and(field.to_sym.nin => [nil, '']).only(:_id, field).order('created_at desc').limit(SAMPLE_SIZE).each do |record|
        value = record.send(field).to_s
        # The start of a field only needs its leading letters (damp_resonance_8's damp...); a whole word, a whole token
        words = first_word ? value.split(/[^\p{L}]+/).reject(&:empty?) : value.scan(SAMPLE_TOKEN)
        candidates = if first_word
                       value.match?(/\A\p{L}/) ? words.first(1) : []
                     else
                       words
                     end
        word = candidates.find { |w| w.match?(SAMPLE_WORD) && words.none? { |other| other.casecmp?(w[0, AUTOCOMPLETE_PREFIX]) } }
        return [record, word] if word
      end
      nil
    end

    def found(model, record, query, **)
      ids = model.search(query, model.and(id: record.id), regex_search: false, **).pluck(:id)
      [ids.include?(record.id), %("#{query}")]
    end
  end
end
