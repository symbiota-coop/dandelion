class Deepwiki
  REPO = 'symbiota-coop/dandelion'
  API_HOST = 'https://api.devin.ai'
  HOST = 'https://deepwiki.com'
  RESULT_URL = "#{HOST}/search"
  WIKI_URL = "#{HOST}/#{REPO}"
  MODE = 'fast'
  QUESTION_LIMIT = 2_000
  QUERY_ID = /\A[a-z0-9-]{1,80}_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  USER_FOCUS = <<~TEXT.freeze
    This question is from a Dandelion organiser or attendee using the product, not a developer reading the code.
    Answer in product terms: what to click and what happens.
    Never mention file names, file paths, partials, models, routes, helpers, class names, or line numbers.
    Do not include a Notes section.
  TEXT

  Result = Struct.new(:query_id, :question, :markdown, :state, :error, keyword_init: true) do
    def source_url
      "#{RESULT_URL}/#{query_id}?mode=#{MODE}"
    end

    def done?
      state.to_s == 'done'
    end

    def failed?
      state.to_s == 'error' || !!error
    end

    def finished?
      done? || failed?
    end
  end

  class << self
    def query_id?(query_id)
      query_id.to_s.match?(QUERY_ID)
    end

    def ask(question)
      new.ask(question)
    end

    def fetch(query_id)
      new.fetch(query_id)
    end

    def pending(query_id, question: nil)
      Result.new(query_id: query_id, question: question.to_s, markdown: '', state: 'pending')
    end

    def result(query_id)
      return unless query_id?(query_id)

      fetch(query_id) || pending(query_id)
    end
  end

  def ask(question)
    question = question.to_s.strip
    return if question.empty?

    question = question[0, QUESTION_LIMIT]
    query_id = query_id_for(question)
    response = connection.post('/ada/query') do |req|
      req.body = {
        mode: MODE,
        user_query: wrapped_query(question),
        keywords: [],
        repo_names: [REPO],
        additional_context: '',
        query_id: query_id,
        use_notes: false,
        generate_summary: false,
        source: 'ada.deepwiki_public'
      }
    end

    return unless response.success?

    Result.new(query_id: query_id, question: question, markdown: '', state: 'pending')
  rescue Faraday::Error => e
    ErrorReporting.capture_exception(e)
    nil
  end

  def fetch(query_id)
    return unless self.class.query_id?(query_id)

    response = connection.get("/ada/query/#{query_id}")
    return unless response.success?

    data = response.body
    data = JSON.parse(data) if data.is_a?(String)
    query = Array(data && data['queries']).last
    return unless query

    Result.new(
      query_id: query_id,
      question: unwrap_question(query['user_query']),
      markdown: answer_markdown(query['response']),
      state: query['state'],
      error: query['error']
    )
  rescue Faraday::Error, JSON::ParserError => e
    ErrorReporting.capture_exception(e)
    nil
  end

  private

  def connection
    Faraday.new(url: API_HOST) do |f|
      f.headers['Origin'] = HOST
      f.headers['Referer'] = "#{HOST}/"
      f.request :json
      f.response :json, content_type: /json/
      f.options.timeout = 10
      f.options.open_timeout = 5
      f.adapter Faraday.default_adapter
    end
  end

  def wrapped_query(question)
    "<relevant_context>#{USER_FOCUS.squish}</relevant_context>#{question}"
  end

  def unwrap_question(user_query)
    user_query.to_s.sub(%r{\A<relevant_context>.*?</relevant_context>}m, '')
  end

  def answer_markdown(items)
    markdown = Array(items).filter_map { |item| item['data'] if item['type'] == 'chunk' }.join
    separate_lists(
      markdown.sub(/\A\s*## Answer\s*/i, '')
              .gsub(%r{\]\(/wiki/([^)#]+)(?:\#([^)]+))?\)}x) { "](#{HOST}/#{[Regexp.last_match(1), Regexp.last_match(2)].compact.join('/')})" }
              .gsub('](/symbiota-coop/', "](#{HOST}/symbiota-coop/")
              .gsub(%r{\[([^\]]+?) \(#{Regexp.escape(REPO)}\)\]}, '[\1]')
              .gsub(/ +([.,;:])/, '\1')
    )
  end

  def separate_lists(markdown)
    list = /\s*(?:[-*+]|\d+\.)\s/
    markdown.split(/(```.*?```)/m).map do |part|
      next part if part.start_with?('```')

      part.gsub(/^(?!#{list})(\S.*)\n(?=#{list})/, "\\1\n\n")
    end.join
  end

  def query_id_for(question)
    slug = question.parameterize.tr('_', '-').squeeze('-')[0, 30].to_s.sub(/\A-+/, '').sub(/-+\z/, '')
    slug = 'question' if slug.empty?
    "#{slug}_#{SecureRandom.uuid}"
  end
end
