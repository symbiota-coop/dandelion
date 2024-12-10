class OpenRouter
  BASE_URL = 'https://openrouter.ai'.freeze
  DEFAULT_MODEL = 'meta-llama/llama-3.3-70b-instruct'.freeze
  DEFAULT_PROVIDERS = %w[Fireworks Together Avian Lepton].freeze
  DEFAULT_CONTEXT_WINDOW = 128_000

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

  def chat(prompt, full_response: false, max_tokens: nil, model: DEFAULT_MODEL, providers: DEFAULT_PROVIDERS)
    prompt = prompt[0..(DEFAULT_CONTEXT_WINDOW * 4 * 0.66)]

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

    response = @client.post('/api/v1/chat/completions') do |req|
      req.headers['Content-Type'] = 'application/json'
      req.headers['Authorization'] = "Bearer #{ENV['OPENROUTER_API_KEY']}"
      req.body = payload
    end

    full_response ? response.body : response.body.dig('choices', 0, 'message', 'content')
  end
end
