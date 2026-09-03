class OpenRouter
  BASE_URL = 'https://openrouter.ai'.freeze
  CHAT_DEFAULTS = {
    model: '~google/gemini-flash-latest',
    context_window_size: 1_000_000,
    reasoning_effort: 'low'
  }.freeze
  PROMPT_LOG_LIMIT = 10_000

  class << self
    def chat(prompt, **)
      new.chat(prompt, **)
    end

    def embedding(input, **)
      new.embedding(input, **)
    end

    def transcribe(audio, **)
      new.transcribe(audio, **)
    end
  end

  def initialize
    @client = Faraday.new(url: BASE_URL) do |conn|
      conn.request :json
      conn.response :json
      # Only Faraday::RetriableResponse (retry_statuses), not timeouts — so embedding timeouts stay a hard cap.
      conn.request :retry, max: 3, interval: 0.5, backoff_factor: 2,
                           retry_statuses: [429, 500, 502, 503, 504],
                           exceptions: [Faraday::RetriableResponse]
      conn.adapter Faraday.default_adapter
    end
  end

  def chat(prompt, full_response: false, schema: nil, model: CHAT_DEFAULTS[:model], providers: nil, context_window_size: CHAT_DEFAULTS[:context_window_size], reasoning_effort: CHAT_DEFAULTS[:reasoning_effort], audio: nil, audio_format: 'ogg')
    prompt = prompt[0..(context_window_size * 4 * 0.66)] unless audio

    content = if audio
                audio_base64 = Base64.strict_encode64(audio)
                [
                  { type: 'text', text: prompt },
                  { type: 'input_audio', input_audio: { data: audio_base64, format: audio_format } }
                ]
              else
                prompt
              end

    payload = {
      model: model,
      messages: [
        {
          role: 'user',
          content: content
        }
      ]
    }

    if providers
      payload[:provider] = { order: providers }
      payload[:allow_fallbacks] = 'false'
    end

    payload[:reasoning] = { effort: reasoning_effort } if reasoning_effort

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

    result = nil
    3.times do
      response = api_post('/api/v1/chat/completions', payload)

      if full_response
        result = response.body
      else
        r = response.body.dig('choices', 0, 'message', 'content')
        result = schema ? JSON.parse(r) : r
      end

      break if result
    end

    log_generation(prompt, result, model) if result

    result
  end

  def embedding(input, full_response: false, model: 'google/gemini-embedding-001', timeout: nil)
    payload = {
      model: model,
      input: input
    }

    response = api_post('/api/v1/embeddings', payload, timeout: timeout)

    if full_response
      response.body
    else
      response.body.dig('data', 0, 'embedding')
    end
  end

  def transcribe(audio, format: 'ogg', model: 'nvidia/parakeet-tdt-0.6b-v3', full_response: false, language: nil, timeout: nil)
    audio_bytes = if audio.is_a?(String)
                    audio
                  else
                    audio.rewind if audio.respond_to?(:rewind)
                    audio.read
                  end

    payload = {
      model: model,
      input_audio: {
        data: Base64.strict_encode64(audio_bytes),
        format: format
      }
    }
    payload[:language] = language if language

    response = api_post('/api/v1/audio/transcriptions', payload, timeout: timeout)

    if full_response
      response.body
    else
      response.body['text']
    end
  end

  private

  def log_generation(prompt, result, model)
    response_text = case result
                    when String then result
                    else result.to_json
                    end
    OpenRouterGeneration.create(
      prompt: prompt.to_s[0, PROMPT_LOG_LIMIT],
      response: response_text,
      model: model,
      source: generation_source
    )
  rescue StandardError => e
    ErrorReporting.capture_exception(e)
  end

  def generation_source
    loc = caller_locations.find do |l|
      path = l.absolute_path || l.path
      next if path.nil? || path.end_with?('open_router.rb')

      path.include?('/app/') || path.include?('/models/') || path.include?('/lib/') || path.include?('/scripts/')
    end
    return unless loc

    path = loc.absolute_path || loc.path
    root = defined?(Padrino) && Padrino.respond_to?(:root) ? Padrino.root.to_s : Dir.pwd
    relative = path.sub(%r{\A#{Regexp.escape(root)}/?}, '')
    "#{relative}:#{loc.lineno}"
  end

  def api_post(endpoint, payload, timeout: nil)
    operation_name = case endpoint
                     when /embeddings/ then 'embeddings'
                     when /transcriptions/ then 'transcriptions'
                     else 'chat'
                     end
    span_op = operation_name == 'embeddings' ? 'gen_ai.embeddings' : 'gen_ai.request'

    Sentry.with_child_span(op: span_op, description: "#{operation_name} #{payload[:model]}") do |span|
      span&.set_data('gen_ai.operation.name', operation_name)
      span&.set_data('gen_ai.request.model', payload[:model])
      span&.set_data('url', "#{BASE_URL}#{endpoint}")
      span&.set_data('http.request.method', 'POST')
      span&.set_data('openrouter.endpoint', endpoint)

      response = @client.post(endpoint) do |req|
        req.headers['Content-Type'] = 'application/json'
        req.headers['Authorization'] = "Bearer #{ENV['OPENROUTER_API_KEY']}"
        req.body = payload
        if timeout
          req.options.timeout = timeout
          req.options.open_timeout = timeout
        end
      end

      span&.set_http_status(response.status)
      usage = response.body['usage'] if response.body.is_a?(Hash)
      if usage
        span&.set_data('gen_ai.usage.input_tokens', usage['prompt_tokens']) if usage['prompt_tokens']
        span&.set_data('gen_ai.usage.output_tokens', usage['completion_tokens']) if usage['completion_tokens']
        span&.set_data('gen_ai.usage.total_tokens', usage['total_tokens']) if usage['total_tokens']
      end

      response
    end
  end
end
