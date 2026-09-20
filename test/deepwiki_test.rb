require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class DeepwikiTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  QUERY_ID = 'how-do-events-work-on-dandelio_11111111-2222-3333-4444-555555555555'

  test 'Deepwiki.ask posts the question and returns a pending result' do
    SecureRandom.stub :uuid, '11111111-2222-3333-4444-555555555555' do
      stub_deepwiki do |requests|
        result = Deepwiki.ask('How do events work on Dandelion?')

        assert_equal 1, requests.length
        body = requests.first
        assert_equal 'fast', body['mode']
        assert_equal ['symbiota-coop/dandelion'], body['repo_names']
        assert_equal 'ada.deepwiki_public', body['source']
        assert_includes body['user_query'], 'How do events work on Dandelion?'
        assert_includes body['user_query'], 'Never mention file names'
        assert_equal '', body['additional_context']
        refute_includes result.question, 'relevant_context'
        assert_equal QUERY_ID, body['query_id']
        assert_equal QUERY_ID, result.query_id
        assert_equal 'How do events work on Dandelion?', result.question
        assert_equal 'pending', result.state
        assert_equal "https://deepwiki.com/search/#{QUERY_ID}?mode=fast", result.source_url
      end
    end
  end

  test 'Deepwiki.ask returns nil when the API fails' do
    stub_deepwiki(post_status: 500) do
      assert_nil Deepwiki.ask('How do events work?')
    end
  end

  test 'Deepwiki.fetch unwraps the question and joins answer chunks' do
    stub_deepwiki(get_body: {
      'queries' => [{
        'user_query' => '<relevant_context>This query was sent from the Dandelion docs page: Events.</relevant_context>How do ticket types work?',
        'state' => 'done',
        'error' => nil,
        'response' => [
          { 'type' => 'chunk', 'data' => "## Answer\n\nTicket types set the price.\n" },
          { 'type' => 'reference', 'data' => { 'file_path' => 'models/ticket_type.rb' } },
          { 'type' => 'chunk', 'data' => "See [Glossary (symbiota-coop/dandelion)](/wiki/symbiota-coop/dandelion#12).\n\nWiki pages you might want to explore:\n- [Carousels and Featured Events (symbiota-coop/dandelion)](/wiki/symbiota-coop/dandelion#6.4)\n" },
          { 'type' => 'done' }
        ]
      }]
    }) do
      result = Deepwiki.fetch(QUERY_ID)
      assert_equal 'How do ticket types work?', result.question
      assert result.done?
      assert_includes result.markdown, 'Ticket types set the price.'
      refute_includes result.markdown, '## Answer'
      assert_includes result.markdown, '[Glossary](https://deepwiki.com/symbiota-coop/dandelion/12)'
      assert_includes result.markdown, "Wiki pages you might want to explore:\n\n- [Carousels and Featured Events]"
    end
  end

  test 'POST /docs/deepwiki redirects to the local answer page' do
    SecureRandom.stub :uuid, '11111111-2222-3333-4444-555555555555' do
      stub_deepwiki do
        post '/docs/deepwiki', q: 'How do events work on Dandelion?'
        assert last_response.redirect?
        assert last_response['Location'].end_with?("/docs/ask/#{QUERY_ID}")
      end
    end
  end

  test 'GET /docs/ask/:query_id/answer.json streams the rendered answer' do
    stub_deepwiki(get_body: {
      'queries' => [{
        'user_query' => 'How do events work?',
        'state' => 'pending',
        'error' => nil,
        'response' => [{ 'type' => 'chunk', 'data' => 'Events live under organisations.' }]
      }]
    }) do
      get "/docs/ask/#{QUERY_ID}/answer.json"
      assert last_response.ok?
      json = JSON.parse(last_response.body)
      assert_includes json['html'], 'Events live under organisations.'
      refute json['done']
      refute json['failed']
      assert_equal "https://deepwiki.com/search/#{QUERY_ID}?mode=fast", json['source_url']
    end
  end

  test 'GET /docs/ask/:query_id renders the question and DeepWiki link' do
    stub_deepwiki(get_body: {
      'queries' => [{
        'user_query' => 'How do events work?',
        'state' => 'done',
        'error' => nil,
        'response' => [{ 'type' => 'chunk', 'data' => 'Events live under organisations.' }]
      }]
    }) do
      get "/docs/ask/#{QUERY_ID}"
      assert last_response.ok?
      assert_includes last_response.body, 'How do events work?'
      assert_includes last_response.body, 'Events live under organisations.'
      assert_includes last_response.body, "https://deepwiki.com/search/#{QUERY_ID}?mode=fast"
      assert_includes last_response.body, 'View this answer on DeepWiki'
    end
  end

  test 'GET /docs/ask/:query_id stays pending when DeepWiki fetch fails' do
    SecureRandom.stub :uuid, '11111111-2222-3333-4444-555555555555' do
      stub_deepwiki(get_status: 500) do
        post '/docs/deepwiki', q: 'How do events work on Dandelion?'
        follow_redirect!
        assert last_response.ok?
        assert_includes last_response.body, 'Ask DeepWiki'
        assert_includes last_response.body, "/docs/ask/#{QUERY_ID}/answer.json"
      end
    end
  end

  test 'GET /docs/ask/:query_id/answer.json stays pending when DeepWiki fetch fails' do
    stub_deepwiki(get_status: 500) do
      get "/docs/ask/#{QUERY_ID}/answer.json"
      assert last_response.ok?
      json = JSON.parse(last_response.body)
      assert_equal '', json['html']
      refute json['done']
      refute json['failed']
      assert_equal "https://deepwiki.com/search/#{QUERY_ID}?mode=fast", json['source_url']
    end
  end

  test 'GET /docs/ask/:query_id 404s for an invalid query id' do
    get '/docs/ask/not-a-query-id'
    assert last_response.not_found?
  end

  def stub_deepwiki(post_status: 200, get_status: 200, get_body: nil)
    requests = []
    get_body ||= {
      'queries' => [{
        'user_query' => 'How do events work?',
        'state' => 'pending',
        'error' => nil,
        'response' => []
      }]
    }

    connection_builder = lambda do |*args, **kwargs, &block|
      Faraday::Connection.new(*args, **kwargs) do |f|
        block&.call(f)
        f.adapter :test do |stub|
          stub.post('/ada/query') do |env|
            requests << JSON.parse(env.body)
            [post_status, { 'Content-Type' => 'application/json' }, '{"status":"success"}']
          end
          stub.get(%r{\A/ada/query/}) do
            [get_status, { 'Content-Type' => 'application/json' }, get_body.to_json]
          end
        end
      end
    end

    Faraday.stub(:new, connection_builder) { yield requests }
  end
end
