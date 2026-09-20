class Deepwiki
  REPO = 'symbiota-coop/dandelion'
  HOST = 'https://deepwiki.com'
  RESULT_URL = "#{HOST}/search"
  WIKI_URL = "#{HOST}/#{REPO}"
  MODE = 'fast'
  QUESTION_LIMIT = 2_000
  QUERY_ID = /\A[a-z0-9-]{1,80}_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  class << self
    def query_id?(query_id)
      query_id.to_s.match?(QUERY_ID)
    end

    def normalize_question(question)
      question = question.to_s.strip
      return if question.empty?

      question[0, QUESTION_LIMIT]
    end

    def source_url(query_id)
      "#{RESULT_URL}/#{query_id}?mode=#{MODE}"
    end
  end
end
