class OpenRouter
  BASE_URL = 'https://openrouter.ai'.freeze
  INTELLIGENCE_LEVELS = {
    'standard' => 'anthropic/claude-haiku-4.5',
    'smarter' => 'anthropic/claude-haiku-4.5:thinking'
  }.freeze
  DEFAULT_PROVIDERS = {
    # 'anthropic/claude-haiku-4.5' => %w[Anthropic],
    # 'anthropic/claude-haiku-4.5:thinking' => %w[Anthropic]
  }.freeze
  DEFAULT_CONTEXT_WINDOW_SIZES = {
    'anthropic/claude-haiku-4.5' => 200_000,
    'anthropic/claude-haiku-4.5:thinking' => 200_000
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
