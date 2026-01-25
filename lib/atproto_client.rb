class AtprotoClient
  PUBLIC_API = 'https://public.api.bsky.app/xrpc'.freeze
  BSKY_API = 'https://bsky.social/xrpc'.freeze

  def initialize(handle: nil, app_password: nil)
    @handle = handle || ENV['ATPROTO_HANDLE']
    @app_password = app_password || ENV['ATPROTO_APP_PASSWORD']
    @session = nil

    @public_client = Faraday.new(url: PUBLIC_API) do |conn|
      conn.request :json
      conn.response :json
      conn.response :raise_error
    end

    @auth_client = Faraday.new(url: BSKY_API) do |conn|
      conn.request :json
      conn.response :json
      conn.response :raise_error
    end
  end

  # Public API methods (no auth required)

  def get_author_feed(handle, limit: 10)
    did = resolve_handle(handle)

    response = @public_client.get('app.bsky.feed.getAuthorFeed', {
                                    actor: did,
                                    limit: limit
                                  })

    response.body
  end

  def resolve_handle(handle)
    response = @public_client.get('com.atproto.identity.resolveHandle', {
                                    handle: handle
                                  })

    response.body['did']
  end

  def get_user_info(handle, display_name: nil)
    did = resolve_handle(handle)

    {
      'handle' => handle,
      'did' => did,
      'displayName' => display_name || handle
    }
  rescue StandardError
    nil
  end

  def get_profile(actor)
    response = @public_client.get('app.bsky.actor.getProfile', { actor: actor })
    response.body
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

      response = @auth_client.get('com.atproto.repo.listRecords', params)
      records = response.body['records'] || []
      all_records.concat(records)

      cursor = response.body['cursor']
      break if cursor.nil? || records.empty?
    end

    all_records
  end

  # Authenticated API methods

  def create_session
    response = @auth_client.post('com.atproto.server.createSession', {
                                   identifier: @handle,
                                   password: @app_password
                                 })
    @session = response.body
  end

  def create_record(collection:, record:)
    ensure_session

    response = @auth_client.post('com.atproto.repo.createRecord', {
                                   repo: @session['did'],
                                   collection: collection,
                                   record: record
                                 }) do |req|
      req.headers['Authorization'] = "Bearer #{@session['accessJwt']}"
    end

    response.body
  end

  def delete_record(uri:)
    ensure_session

    parts = uri.split('/')
    rkey = parts.last
    collection = parts[-2]

    @auth_client.post('com.atproto.repo.deleteRecord', {
                        repo: @session['did'],
                        collection: collection,
                        rkey: rkey
                      }) do |req|
      req.headers['Authorization'] = "Bearer #{@session['accessJwt']}"
    end
  end

  def put_record(collection:, rkey:, record:)
    ensure_session

    response = @auth_client.post('com.atproto.repo.putRecord', {
                                   repo: @session['did'],
                                   collection: collection,
                                   rkey: rkey,
                                   record: record
                                 }) do |req|
      req.headers['Authorization'] = "Bearer #{@session['accessJwt']}"
    end

    response.body
  end

  private

  def ensure_session
    create_session unless @session
  end
end
