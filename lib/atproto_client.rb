class AtprotoClient
  API_URL = 'https://bsky.social/xrpc'.freeze

  def initialize(handle: nil, app_password: nil)
    @handle = handle || ENV['ATPROTO_HANDLE']
    @app_password = app_password || ENV['ATPROTO_APP_PASSWORD']
    @session = nil

    @client = Faraday.new(url: API_URL) do |conn|
      conn.request :json
      conn.response :json
      conn.response :raise_error
    end
  end

  def resolve_handle(handle)
    get('com.atproto.identity.resolveHandle', handle: handle)['did']
  end

  def get_user_info(handle, display_name: nil)
    did = resolve_handle(handle)
    { 'handle' => handle, 'did' => did, 'displayName' => display_name || handle }
  rescue StandardError
    nil
  end

  def get_author_feed(handle, limit: 10)
    did = resolve_handle(handle)
    get('app.bsky.feed.getAuthorFeed', actor: did, limit: limit)
  end

  def get_profile(actor)
    get('app.bsky.actor.getProfile', actor: actor)
  rescue StandardError
    nil
  end

  def list_records(collection:, repo: nil, handle: nil, limit: 100)
    repo ||= resolve_handle(handle) if handle
    raise ArgumentError, 'Must provide repo or handle' unless repo

    all_records = []
    cursor = nil

    loop do
      params = { repo: repo, collection: collection, limit: limit }
      params[:cursor] = cursor if cursor

      response = get('com.atproto.repo.listRecords', params)
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

  def delete_record(uri:)
    parts = uri.split('/')
    rkey = parts.last
    collection = parts[-2]
    post('com.atproto.repo.deleteRecord', repo: session['did'], collection: collection, rkey: rkey)
  end

  def put_record(collection:, rkey:, record:)
    post('com.atproto.repo.putRecord', repo: session['did'], collection: collection, rkey: rkey, record: record)
  end

  private

  def session
    @session ||= @client.post('com.atproto.server.createSession', {
                                identifier: @handle,
                                password: @app_password
                              }).body
  end

  def get(endpoint, params = {})
    @client.get(endpoint, params) { |req| req.headers['Authorization'] = "Bearer #{session['accessJwt']}" }.body
  end

  def post(endpoint, body = {})
    @client.post(endpoint, body) { |req| req.headers['Authorization'] = "Bearer #{session['accessJwt']}" }.body
  end
end
