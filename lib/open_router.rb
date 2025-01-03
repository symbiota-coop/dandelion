class OpenRouter
  BASE_URL = 'https://openrouter.ai'.freeze
  DEFAULT_MODEL = 'meta-llama/llama-3.3-70b-instruct'.freeze
  DEFAULT_PROVIDERS = {
    'meta-llama/llama-3.3-70b-instruct' => %w[Lepton Fireworks Together Avian],
    'deepseek/deepseek-chat' => %w[DeepSeek],
    'anthropic/claude-3.5-sonnet:beta' => %w[Anthropic]
  }.freeze
  DEFAULT_CONTEXT_WINDOW_SIZES = {
    'meta-llama/llama-3.3-70b-instruct' => 128_000,
    'deepseek/deepseek-chat' => 64_000,
    'anthropic/claude-3.5-sonnet:beta' => 200_000
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

  def chat(prompt, full_response: false, max_tokens: nil, schema: nil, model: DEFAULT_MODEL, providers: nil, context_window_size: nil)
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
