Dandelion::App.controller do
  get '/whatsapp' do
    halt 400 unless params[:'hub.verify_token'] == ENV['WHATSAPP_VERIFY_TOKEN']
    params[:'hub.challenge']
  end

  post '/whatsapp' do
    token = ENV['WHATSAPP_ACCESS_TOKEN']
    http_client = HTTP.auth("Bearer #{token}")

    body = JSON.parse(request.body.read)
    message = body.dig('entry', 0, 'changes', 0, 'value', 'messages', 0)
    halt 200 unless message && message['type'] == 'audio'

    media_id = message['audio']['id']

    # get the media url
    media_url = "https://graph.facebook.com/v21.0/#{media_id}"
    response = http_client.get(media_url)
    media_download_url = JSON.parse(response.body)['url']

    # download the media
    response = http_client.get(media_download_url)
    temp_file = Tempfile.new(['whatsapp_media', File.extname(media_download_url)])
    temp_file.binmode
    temp_file.write(response.body)
    temp_file.rewind

    # transcribe the audio
    conn = Faraday.new(url: 'https://api.openai.com/v1') do |f|
      f.request :multipart
      f.request :url_encoded
      f.adapter Faraday.default_adapter
    end

    response = conn.post('/v1/audio/transcriptions') do |req|
      req.headers['Authorization'] = "Bearer #{ENV['OPENAI_API_KEY']}"
      req.body = {
        model: 'whisper-1',
        file: Faraday::UploadIO.new(temp_file.path, 'audio/ogg')
      }
    end

    text = JSON.parse(response.body)['text']

    # close and delete the temporary file
    temp_file.close
    temp_file.unlink

    # send the transcription to the user
    to = message['from']
    messages_url = "https://graph.facebook.com/v21.0/#{ENV['WHATSAPP_PHONE_NUMBER_ID']}/messages"

    # split the text into chunks of approximately 2048 characters at word boundaries
    chunks = []
    current_chunk = ''
    text.split.each do |word|
      if (current_chunk + ' ' + word).length <= 2048
        current_chunk += (current_chunk.empty? ? '' : ' ') + word
      else
        chunks << current_chunk
        current_chunk = word
      end
    end
    chunks << current_chunk unless current_chunk.empty?
    total_chunks = chunks.size

    chunks.each_with_index do |chunk, index|
      payload = {
        messaging_product: 'whatsapp',
        to: to,
        type: 'text',
        text: {
          body: total_chunks > 1 ? "#{chunk} (#{index + 1}/#{total_chunks})" : chunk
        }
      }
      http_client.post(messages_url, json: payload)
    end

    200
  end
end
