class OpenRouter
  BASE_URL = 'https://openrouter.ai'.freeze
  INTELLIGENCE_LEVELS = {
    'standard' => 'google/gemini-2.5-flash',
    'smarter' => 'google/gemini-2.5-flash:thinking'
  }.freeze
  DEFAULT_PROVIDERS = {
    'google/gemini-2.5-flash' => %w[Google],
    'google/gemini-2.5-flash:thinking' => %w[Google]
  }.freeze
  DEFAULT_CONTEXT_WINDOW_SIZES = {
    'google/gemini-2.5-flash' => 1_000_000,
    'google/gemini-2.5-flash:thinking' => 1_000_000
  }.freeze

  class << self
    def chat(prompt, **)
      new.chat(prompt, **)
    end
  end

  def initialize
    @client = Faraday.new(url: BASE_URL) do |conn|
      conn.request :json
      conn.response :json
      conn.adapter Faraday.default_adapter
    end
  end

  def chat(prompt, full_response: false, max_tokens: nil, schema: nil, model: INTELLIGENCE_LEVELS['standard'], providers: nil, context_window_size: nil, intelligence: nil)
    model = INTELLIGENCE_LEVELS[intelligence] if intelligence
    providers ||= DEFAULT_PROVIDERS[model]
    context_window_size ||= DEFAULT_CONTEXT_WINDOW_SIZES[model]
    prompt = prompt[0..(context_window_size * 4 * 0.66)]

    payload = {
      model: model,
      max_tokens: max_tokens,
      messages: [
        {
          role: 'user',
          content: prompt
        }
      ],
      provider: {
        order: providers
      },
      allow_fallbacks: 'false'
    }

    if schema
      payload[:response_format] = {
        type: 'json_schema',
        json_schema: {
          name: 'response',
          strict: true,
          schema: schema
        }
      }
    end

    response = @client.post('/api/v1/chat/completions') do |req|
      req.headers['Content-Type'] = 'application/json'
      req.headers['Authorization'] = "Bearer #{ENV['OPENROUTER_API_KEY']}"
      req.body = payload
    end

    if full_response
      response.body
    else
      r = response.body.dig('choices', 0, 'message', 'content')
      schema ? JSON.parse(r) : r
    end
  end
end
