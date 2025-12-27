class AtprotoClient
  PUBLIC_API = 'https://public.api.bsky.app/xrpc'.freeze

  def initialize
    @client = Faraday.new(url: PUBLIC_API) do |conn|
      conn.request :json
      conn.response :json
      conn.response :raise_error
    end
  end

  def get_author_feed(handle, limit: 10)
    did = resolve_handle(handle)

    response = @client.get('app.bsky.feed.getAuthorFeed', {
                             actor: did,
                             limit: limit
                           })

    response.body
  end

  def resolve_handle(handle)
    response = @client.get('com.atproto.identity.resolveHandle', {
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
end
