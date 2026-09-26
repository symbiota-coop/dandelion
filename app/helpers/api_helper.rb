Dandelion::App.helpers do
  def api_halt(status, error, description)
    halt status, { 'Content-Type' => 'application/json' }, { error: error, error_description: description }.to_json
  end

  # Bearer API key only: no session cookies, so no CSRF exposure
  def api_account!
    account = Dandelion::API.account_from_request(request)
    headers 'WWW-Authenticate' => 'Bearer' unless account.is_a?(Account)
    api_halt 401, 'unauthorized', 'Provide your API key as a Bearer token' if account.nil?
    api_halt 401, 'invalid_token', 'Invalid API key' if account == :invalid
    account
  end

  def api_body
    request.body.rewind
    body = request.body.read
    return {} if body.blank?

    parsed = JSON.parse(body)
    api_halt 400, 'invalid_request', 'Request body must be a JSON object' unless parsed.is_a?(Hash)
    parsed
  rescue JSON::ParserError
    api_halt 400, 'invalid_request', 'Request body must be valid JSON'
  end

  def api_respond
    content_type :json
    yield.to_json
  rescue Dandelion::API::Error => e
    api_halt e.status, 'invalid_request', e.message
  end
end
