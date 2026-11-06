# The checks /stats/atlas runs on the features only Atlas has, which CI can't test as it runs on plain MongoDB (and dev
# and the tests search with regex): each searchable model's Atlas Search index, and searches through Searchable that use
# it, by whole word (phrase), by the start of a word (autocomplete) and with embeddings ($vectorSearch and $rankFusion).
# Each search is of a real record, narrowed to it by id, so it passes only if that record comes back
module AtlasChecks
  Check = Struct.new(:group, :name, :ok, :detail, :ms, keyword_init: true)

  # $rankFusion, which combines vector and text search, needs MongoDB 8.0
  RANK_FUSION_VERSION = Gem::Version.new('8.0')
  # A word to search for is at least this long, so the start of it searched for (AUTOCOMPLETE_PREFIX letters) isn't the
  # whole word, which a phrase would match without autocomplete
  SAMPLE_WORD = /\A\p{L}{6,}\z/
  AUTOCOMPLETE_PREFIX = 4
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
      field = model.autocomplete_field
      if field
        checks << check(group, "#{field} mapped as autocomplete") do
          raise 'no search index' unless index

          types = Array.wrap(index.dig('latestDefinition', 'mappings', 'fields', field)).map { |mapping| mapping['type'] }
          [types.include?('autocomplete') && types.include?('string'), types.any? ? types.join(', ') : 'not mapped']
        end
      end
      record, word = sample(model, field || model.search_fields.first)
      checks << check(group, 'Whole-word search') do
        raise 'no record with a long enough word to search for' unless record

        found(model, record, word, autocomplete: nil)
      end
      if field
        checks << check(group, 'Search by the start of a word') do
          raise 'no record with a long enough word to search for' unless record

          found(model, record, word[0, AUTOCOMPLETE_PREFIX])
        end
      end
      checks
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

    # A recent record whose field has a word long enough to search for by its start
    def sample(model, field)
      model.and(field.to_sym.nin => [nil, '']).only(:_id, field).order('created_at desc').limit(SAMPLE_SIZE).each do |record|
        words = record.send(field).to_s.split(/[^\p{L}]+/)
        word = words.find { |w| w.match?(SAMPLE_WORD) && words.none? { |other| other.casecmp?(w[0, AUTOCOMPLETE_PREFIX]) } }
        return [record, word] if word
      end
      nil
    end

    def found(model, record, query, **)
      ids = model.search(query, model.and(id: record.id), regex_search: false, **).pluck(:id)
      [ids.include?(record.id), %("#{query}")]
    end

    def check(group, name)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ok, detail = begin
        yield
      rescue StandardError => e
        [false, "#{e.class}: #{e.message.truncate(200)}"]
      end
      Check.new(group: group, name: name, ok: ok, detail: detail, ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
    end
  end
end
