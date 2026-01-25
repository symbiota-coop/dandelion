class AtprotoClient
  API_URL = 'https://bsky.social/xrpc'.freeze
  PUBLIC_API_URL = 'https://public.api.bsky.app/xrpc'.freeze

  def initialize(handle: nil, app_password: nil)
    @handle = handle || ENV['ATPROTO_HANDLE']
    @app_password = app_password || ENV['ATPROTO_APP_PASSWORD']
    @session = nil

    @client = Faraday.new(url: API_URL) do |conn|
      conn.request :json
      conn.response :json
      conn.response :raise_error
    end

    @public_client = Faraday.new(url: PUBLIC_API_URL) do |conn|
      conn.request :json
      conn.response :json
      conn.response :raise_error
    end
  end

  def resolve_handle(handle)
    get('com.atproto.identity.resolveHandle', { handle: handle }, auth: false)['did']
  end

  def get_author_feed(actor, limit: 10)
    get('app.bsky.feed.getAuthorFeed', { actor: actor, limit: limit })
  end

  def get_profile(actor)
    get('app.bsky.actor.getProfile', { actor: actor })
  end

  def list_records(collection:, repo: nil, handle: nil, limit: 100)
    repo ||= resolve_handle(handle) if handle
    raise ArgumentError, 'Must provide repo or handle' unless repo

    all_records = []
    cursor = nil

    loop do
      params = { repo: repo, collection: collection, limit: limit }
      params[:cursor] = cursor if cursor

      response = get('com.atproto.repo.listRecords', params, auth: false)
      records = response['records'] || []
      all_records.concat(records)

      cursor = response['cursor']
      break if cursor.nil? || records.empty?
    end

    all_records
  end

  def create_record(collection:, record:)
    post('com.atproto.repo.createRecord', repo: session['did'], collection: collection, record: record)
  end

  def put_record(uri:, record:)
    collection, rkey = parse_uri(uri)
    post('com.atproto.repo.putRecord', repo: session['did'], collection: collection, rkey: rkey, record: record)
  end

  def delete_record(uri:)
    collection, rkey = parse_uri(uri)
    post('com.atproto.repo.deleteRecord', repo: session['did'], collection: collection, rkey: rkey)
  end

  private

  def parse_uri(uri)
    parts = uri.split('/')
    [parts[-2], parts.last]
  end

  def session
    @session ||= @client.post('com.atproto.server.createSession', {
                                identifier: @handle,
                                password: @app_password
                              }).body
  end

  def get(endpoint, params = {}, auth: true)
    if endpoint.start_with?('app.bsky.')
      @public_client.get(endpoint, params).body
    elsif auth
      @client.get(endpoint, params) { |req| req.headers['Authorization'] = "Bearer #{session['accessJwt']}" }.body
    else
      @client.get(endpoint, params).body
    end
  end

  def post(endpoint, body = {})
    @client.post(endpoint, body) { |req| req.headers['Authorization'] = "Bearer #{session['accessJwt']}" }.body
  end
end
