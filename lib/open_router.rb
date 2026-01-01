class OpenRouter
  BASE_URL = 'https://openrouter.ai'.freeze
  INTELLIGENCE_LEVELS = {
    'standard' => 'google/gemini-3-flash-preview',
    'smarter' => 'google/gemini-3-flash-preview:thinking'
  }.freeze
  MODELS = {
    'google/gemini-3-flash-preview' => {
      providers: %w[Google],
      context_window_size: 1_000_000
    },
    'google/gemini-3-flash-preview:thinking' => {
      providers: %w[Google],
      context_window_size: 1_000_000
    }
  }.freeze

  class << self
    def chat(prompt, **)
      new.chat(prompt, **)
    end

    def embedding(input, **)
      new.embedding(input, **)
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
    model_config = MODELS[model] || {}
    providers ||= model_config[:providers]
    context_window_size ||= model_config[:context_window_size]
    prompt = prompt[0..(context_window_size * 4 * 0.66)]

    payload = {
      model: model.split(':thinking').first,
      max_tokens: max_tokens,
      messages: [
        {
          role: 'user',
          content: prompt
        }
      ]
    }

    if providers
      payload[:provider] = { order: providers }
      payload[:allow_fallbacks] = 'false'
    end

    if model.include?(':thinking')
      payload[:reasoning] = {
        enabled: true
      }
    end

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

    response = api_post('/api/v1/chat/completions', payload)

    if full_response
      response.body
    else
      r = response.body.dig('choices', 0, 'message', 'content')
      schema ? JSON.parse(r) : r
    end
  end

  def embedding(input, full_response: false, model: 'google/gemini-embedding-001')
    payload = {
      model: model,
      input: input
    }

    response = api_post('/api/v1/embeddings', payload)

    if full_response
      response.body
    else
      response.body.dig('data', 0, 'embedding')
    end
  end

  private

  def api_post(endpoint, payload)
    @client.post(endpoint) do |req|
      req.headers['Content-Type'] = 'application/json'
      req.headers['Authorization'] = "Bearer #{ENV['OPENROUTER_API_KEY']}"
      req.body = payload
    end
  end
end
