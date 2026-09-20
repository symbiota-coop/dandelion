require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class DeepwikiTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  QUERY_ID = 'how-do-events-work-on-dandelio_11111111-2222-3333-4444-555555555555'

  test 'Deepwiki.normalize_question strips and truncates' do
    assert_nil Deepwiki.normalize_question('   ')
    assert_nil Deepwiki.normalize_question(nil)
    assert_equal 'How do events work?', Deepwiki.normalize_question('  How do events work?  ')
    assert_equal 'a' * Deepwiki::QUESTION_LIMIT, Deepwiki.normalize_question('a' * (Deepwiki::QUESTION_LIMIT + 10))
  end

  test 'Deepwiki.query_id? accepts DeepWiki search ids' do
    assert Deepwiki.query_id?(QUERY_ID)
    refute Deepwiki.query_id?('ask')
    refute Deepwiki.query_id?('not-a-query')
  end

  test 'GET /docs/ask renders a question for the browser to send to DeepWiki' do
    get '/docs/ask', q: 'How do events work on Dandelion?'
    assert last_response.ok?
    assert_includes last_response.body, 'How do events work on Dandelion?'
    assert_includes last_response.body, 'data-deepwiki-question="How do events work on Dandelion?"'
    assert_includes last_response.body, 'https://mcp.deepwiki.com/mcp'
    assert_includes last_response.body, '/javascripts/docs_ask.js'
    assert_includes last_response.body, 'flicker'
    refute_includes last_response.body, '/docs/deepwiki'
    refute_includes last_response.body, 'answer.json'
  end

  test 'GET /docs/ask without a question shows the form' do
    get '/docs/ask'
    assert last_response.ok?
    assert_includes last_response.body, 'Ask DeepWiki'
    assert_includes last_response.body, 'action="/docs/ask"'
    assert_includes last_response.body, 'method="get"'
    refute_includes last_response.body, 'data-deepwiki-question'
  end

  test 'GET /docs/events includes the client-side DeepWiki form' do
    get '/docs/events'
    assert last_response.ok?
    assert_includes last_response.body, 'action="/docs/ask"'
    assert_includes last_response.body, 'method="get"'
    assert_includes last_response.body, 'our DeepWiki'
  end

  test 'GET /docs/ask/:query_id redirects to the DeepWiki search page' do
    get "/docs/ask/#{QUERY_ID}"
    assert last_response.redirect?
    assert_equal "https://deepwiki.com/search/#{QUERY_ID}?mode=fast", last_response.headers['Location']
  end

  test 'GET /docs/ask/:query_id 404s for an invalid id' do
    get '/docs/ask/not-a-query'
    assert last_response.not_found?
  end
end
