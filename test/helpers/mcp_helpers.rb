# Helpers the MCP test files (test/integrations) share: JSON-RPC calls to /mcp
module McpHelpers
  include Rack::Test::Methods

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
end
