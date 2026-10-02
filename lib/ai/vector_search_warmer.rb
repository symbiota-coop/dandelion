# Atlas drops the vector index from memory when it sits idle, and the next AI
# searches then hit Searchable::VECTOR_AGGREGATE_MAX_TIME_MS and fall back to
# text search. A cheap $vectorSearch every minute keeps the index warm.
module VectorSearchWarmer
  INTERVAL_SECONDS = 60
  NUM_CANDIDATES = 1_000

  def self.start
    Thread.new do
      loop do
        sleep INTERVAL_SECONDS
        warm
      rescue StandardError => e
        puts "vector search warmer: #{e.class}: #{e.message}"
      end
    end
  end

  def self.warm
    # Use a stored embedding (no OpenRouter call), from a random event each
    # time so the queries visit different parts of the index. $sample as the
    # first stage picks random documents without scanning the collection.
    query_vector = Event.collection.aggregate([
                                                { '$sample' => { size: 20 } },
                                                { '$match' => { embedding: { '$type' => 'array' } } },
                                                { '$limit' => 1 },
                                                { '$project' => { embedding: 1 } }
                                              ]).first&.dig('embedding')
    return unless query_vector

    Event.collection.aggregate([
                                 { '$vectorSearch' => { index: 'vector_index', path: 'embedding', queryVector: query_vector, numCandidates: NUM_CANDIDATES, limit: 1 } },
                                 { '$project' => { _id: 1 } }
                               ]).to_a
  end
end
