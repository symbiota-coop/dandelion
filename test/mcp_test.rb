require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")
require 'rack/test'

class McpTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  def app
    Padrino.application
  end

  def save_screenshot(*); end

  def mcp_post(body, headers: {})
    header 'Content-Type', 'application/json'
    header 'Accept', 'application/json, text/event-stream'
    headers.each { |key, value| header key, value }
    post '/mcp', body.to_json
  end

  def mcp_rpc(method, params: {}, headers: {}, id: 1)
    mcp_post({ jsonrpc: '2.0', id: id, method: method, params: params }, headers: headers)
    JSON.parse(last_response.body)
  end

  def mcp_tool_call(name, arguments: {}, headers: {})
    mcp_rpc('tools/call', params: { name: name, arguments: arguments }, headers: headers)
  end

  def tool_text(rpc)
    rpc.dig('result', 'content', 0, 'text')
  end

  test 'public tools remain available without authentication' do
    rpc = mcp_tool_call('get_trending_events_tool', arguments: { limit: 1 })

    assert_equal 200, last_response.status
    assert rpc.dig('result', 'content')
    refute rpc.dig('result', 'isError')
  end

  test 'tools list includes get_me_tool without authentication' do
    rpc = mcp_rpc('tools/list')

    assert_equal 200, last_response.status
    names = rpc.dig('result', 'tools').map { |tool| tool['name'] }
    assert_includes names, 'get_me_tool'
  end

  test 'get_me_tool requires authentication' do
    rpc = mcp_tool_call('get_me_tool')

    assert_equal 200, last_response.status
    assert rpc.dig('result', 'isError')
    assert_includes tool_text(rpc), 'Authentication required'
  end

  test 'get_me_tool returns the authenticated account' do
    account = FactoryBot.create(:account)

    rpc = mcp_tool_call('get_me_tool', headers: { 'Authorization' => "Bearer #{account.api_key}" })
    payload = JSON.parse(tool_text(rpc))

    assert_equal 200, last_response.status
    refute rpc.dig('result', 'isError')
    assert_equal account.id.to_s, payload['id']
    assert_equal account.name, payload['name']
    assert_equal account.username, payload['username']
    assert_equal account.email, payload['email']
    assert_equal "#{ENV['BASE_URI']}/u/#{account.username}", payload['url']
  end

  test 'invalid bearer token is rejected' do
    mcp_tool_call('get_me_tool', headers: { 'Authorization' => 'Bearer not-a-real-key' })

    assert_equal 401, last_response.status
    assert_equal 'Bearer', last_response['WWW-Authenticate']
    assert_equal 'invalid_token', JSON.parse(last_response.body)['error']
  end
end
