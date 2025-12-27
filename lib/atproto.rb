class AtprotoClient
  PUBLIC_API = 'https://public.api.bsky.app/xrpc'
  AUTH_API = 'https://bsky.social/xrpc'

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

  def display_posts(feed_data)
    feed_data['feed'].each do |item|
      post = item['post']
      record = post['record']
      author = post['author']

      puts '=' * 60
      puts "Author: #{author['displayName']} (@#{author['handle']})"
      puts "Date: #{record['createdAt']}"
      puts '-' * 40
      puts record['text']
      puts
      puts "Likes: #{post['likeCount'] || 0} | Reposts: #{post['repostCount'] || 0} | Replies: #{post['replyCount'] || 0}"
      puts
    end
  end
end
