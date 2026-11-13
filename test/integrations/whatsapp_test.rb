require_relative '../test_config'

# The WhatsApp webhook (app/controllers/whatsapp.rb): Meta's verification of it, signed deliveries only, and a voice
# message from a site admin transcribed (OpenRouter) and sent back to them in pieces WhatsApp takes. Meta's Graph API
# and OpenRouter are faked
class IntegrationsWhatsappTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  SECRET = 'whatsapp-app-secret'.freeze
  ADMIN_PHONE = '447700900123'.freeze

  # Meta's Graph API as the webhook calls it: the audio's download URL, then its bytes, and the messages it sends
  FakeGraph = Struct.new(:requests) do
    def get(url)
      requests << [:get, url]
      body = url.start_with?('https://graph.facebook.com/') ? { url: 'https://lookaside.fbsbx.com/audio.ogg' }.to_json : 'OGG BYTES'
      Struct.new(:body).new(body)
    end

    def post(url, json:)
      requests << [:post, url, json]
    end
  end

  def admin_on_whatsapp
    FactoryBot.create(:account, admin: true).tap { |account| account.set(phone: "+#{ADMIN_PHONE}") }
  end

  def audio_message(from: ADMIN_PHONE, media_id: '12345', type: 'audio')
    message = { from: from, id: "wamid.#{SecureRandom.hex(4)}", type: type }
    message[:audio] = { id: media_id } if type == 'audio'
    { entry: [{ changes: [{ value: { messages: [message] } }] }] }
  end

  # Delivers a payload signed as Meta signs it, with the Graph API and OpenRouter faked; gives the Graph API requests
  def deliver(body, secret: SECRET, transcript: 'um so this is the note', cleaned: 'This is the note.')
    graph = FakeGraph.new([])
    payload = body.to_json
    signature = "sha256=#{OpenSSL::HMAC.hexdigest('sha256', secret, payload)}"
    with_env('WHATSAPP_APP_SECRET' => SECRET, 'WHATSAPP_ACCESS_TOKEN' => 'token', 'WHATSAPP_PHONE_NUMBER_ID' => '999', 'REDIS_URL' => nil) do
      HTTP.stub(:auth, ->(*) { graph }) do
        OpenRouter.stub(:transcribe, ->(*, **) { transcript }) do
          OpenRouter.stub(:chat, ->(*, **) { cleaned }) do
            post '/whatsapp', payload, 'CONTENT_TYPE' => 'application/json', 'HTTP_X_HUB_SIGNATURE_256' => signature
          end
        end
      end
    end
    graph.requests
  end

  def sent_texts(requests)
    requests.select { |request| request.first == :post }.map { |_, _, json| json[:text][:body] }
  end

  test "Meta verifies the webhook with the verify token, and nobody else can" do
    covers_route 'GET /whatsapp'
    with_env('WHATSAPP_VERIFY_TOKEN' => 'verify-me') do
      get '/whatsapp', 'hub.verify_token' => 'verify-me', 'hub.challenge' => '1158201444'
      assert_equal 200, last_response.status
      assert_equal '1158201444', last_response.body

      get '/whatsapp', 'hub.verify_token' => 'wrong', 'hub.challenge' => '1158201444'
      assert_equal 403, last_response.status
      get '/whatsapp', 'hub.challenge' => '1158201444'
      assert_equal 403, last_response.status
    end
    with_env('WHATSAPP_VERIFY_TOKEN' => nil) do
      get '/whatsapp', 'hub.verify_token' => '', 'hub.challenge' => '1'
      assert_equal 403, last_response.status
    end
  end

  test "a delivery not signed with the app secret is refused, and nothing is fetched or sent" do
    covers_route 'POST /whatsapp'
    admin_on_whatsapp
    assert_empty deliver(audio_message, secret: 'not-the-secret')
    assert_equal 403, last_response.status

    with_env('WHATSAPP_APP_SECRET' => SECRET) do
      post '/whatsapp', audio_message.to_json, 'CONTENT_TYPE' => 'application/json'
    end
    assert_equal 403, last_response.status
  end

  test "only a site admin's voice messages are transcribed: others, and messages that aren't audio, are left" do
    FactoryBot.create(:account).set(phone: '+447700900999')
    admin_on_whatsapp

    [audio_message(from: '447700900999'), audio_message(from: '447700900000'), audio_message(type: 'text'),
     audio_message(media_id: '../me')].each do |body|
      assert_empty deliver(body)
      assert_equal 200, last_response.status
    end
  end

  test "a site admin's voice message is transcribed, tidied and sent back to them" do
    admin_on_whatsapp
    requests = deliver(audio_message)

    assert_equal 200, last_response.status
    assert_equal [[:get, 'https://graph.facebook.com/v21.0/12345'], [:get, 'https://lookaside.fbsbx.com/audio.ogg']], requests.first(2)
    assert_equal ['This is the note.'], sent_texts(requests)
    _, url, json = requests.last
    assert_equal 'https://graph.facebook.com/v21.0/999/messages', url
    assert_equal ADMIN_PHONE, json[:to]
  end

  test 'a long transcript is sent in numbered pieces WhatsApp takes, split at paragraphs, and at words in a long one' do
    admin_on_whatsapp
    paragraphs = Array.new(3) { |i| "Paragraph #{i} #{'word ' * 300}".strip }
    long_paragraph = 'long ' * 900
    texts = sent_texts(deliver(audio_message, cleaned: (paragraphs + [long_paragraph.strip]).join("\n\n")))

    assert_operator texts.length, :>, 2
    texts.each_with_index do |text, i|
      assert text.end_with?("(#{i + 1}/#{texts.length})"), text[-20..]
      assert_operator text.length, :<=, 2048 + " (#{texts.length}/#{texts.length})".length
    end
    assert texts.first.start_with?('Paragraph 0')
    assert_equal (paragraphs + [long_paragraph.strip]).join(' ').split.length, texts.map { |text| text.sub(/ \(\d+\/\d+\)\z/, '') }.join(' ').split.length
  end

  test 'a transcription that comes back blank is an error, and nothing is sent' do
    admin_on_whatsapp
    error = assert_raises(RuntimeError) { deliver(audio_message, transcript: '') }
    assert_match(/blank/, error.message)
  end
end
