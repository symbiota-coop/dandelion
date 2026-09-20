class Deepwiki
  REPO = 'symbiota-coop/dandelion'
  API_HOST = 'https://api.devin.ai'
  RESULT_URL = 'https://deepwiki.com/search'
  WIKI_URL = "https://deepwiki.com/#{REPO}"
  MODE = 'fast'
  QUESTION_LIMIT = 2_000
  QUERY_ID = /\A[a-z0-9-]{1,80}_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  PAGES = {
    'events' => 'Events',
    'organisations' => 'Organisations',
    'gatherings' => 'Gatherings',
    'mailer' => 'Mailer',
    'integrations' => 'Zapier & MCP'
  }.freeze
  USER_FOCUS = <<~TEXT.freeze
    Answer for a Dandelion organiser or attendee, not a developer.
    Explain what to click and what happens in the product.
    Do not cite file paths or line numbers.
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

    def ask(question, page: nil)
      new.ask(question, page: page)
    end

    def fetch(query_id)
      new.fetch(query_id)
    end

    def pending(query_id, question: nil)
      Result.new(query_id: query_id, question: question.to_s, markdown: '', state: 'pending')
    end
  end

  def ask(question, page: nil)
    question = question.to_s.strip
    return if question.empty?

    question = question[0, QUESTION_LIMIT]
    query_id = query_id_for(question)
    response = connection.post('/ada/query') do |req|
      req.headers['Origin'] = 'https://deepwiki.com'
      req.headers['Referer'] = 'https://deepwiki.com/'
      req.body = {
        mode: MODE,
        user_query: wrapped_query(question, page),
        keywords: [],
        repo_names: [REPO],
        additional_context: USER_FOCUS,
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

    response = connection.get("/ada/query/#{query_id}") do |req|
      req.headers['Origin'] = 'https://deepwiki.com'
      req.headers['Referer'] = 'https://deepwiki.com/'
    end
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
      f.request :json
      f.response :json, content_type: /json/
      f.options.timeout = 10
      f.options.open_timeout = 5
      f.adapter Faraday.default_adapter
    end
  end

  def wrapped_query(question, page)
    "<relevant_context>This query was sent from the Dandelion docs page: #{page_title(page)}.</relevant_context>#{question}"
  end

  def page_title(page)
    PAGES[page.to_s.strip.downcase] || 'Overview'
  end

  def unwrap_question(user_query)
    user_query.to_s.sub(%r{\A<relevant_context>.*?</relevant_context>}m, '')
  end

  def answer_markdown(items)
    markdown = Array(items).filter_map { |item| item['data'] if item['type'] == 'chunk' }.join
    separate_lists(
      markdown.sub(/\A\s*## Answer\s*/i, '')
              .gsub(%r{\]\(/wiki/([^)#]+)(?:\#([^)]+))?\)}x) do
                path = Regexp.last_match(1)
                section = Regexp.last_match(2)
                section ? "](https://deepwiki.com/#{path}/#{section})" : "](https://deepwiki.com/#{path})"
              end
              .gsub('](/symbiota-coop/', '](https://deepwiki.com/symbiota-coop/')
              .gsub(%r{\[([^\]]+?) \(symbiota-coop/dandelion\)\]}, '[\1]')
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
    slug = question.downcase.gsub(/[^a-z0-9\s]/, '').gsub(/\s+/, '-')[0, 30].to_s.sub(/-+\z/, '')
    slug = 'question' if slug.empty?
    "#{slug}_#{SecureRandom.uuid}"
  end
end
