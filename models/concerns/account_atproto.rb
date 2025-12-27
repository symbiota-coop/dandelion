module AccountAtproto
  extend ActiveSupport::Concern

  def atproto_posts
    return unless atproto_handle

    client = AtprotoClient.new
    feed_data = client.get_author_feed(atproto_handle, limit: 25)

    feed_data['feed'] || []
  rescue StandardError
    nil
  end

  def atproto_links
    posts = atproto_posts
    return unless posts

    links = []
    posts.each do |item|
      post = item['post']
      record = post['record']
      next unless record

      # Check for external embeds (posts that embed external URLs)
      embed = post['embed']
      next unless embed && embed['$type'] == 'app.bsky.embed.external#view'
      next unless embed['external']

      external = embed['external']
      # Only require URL, image is optional
      next unless external['uri']

      link_data = {
        'url' => external['uri'],
        'title' => external['title'] || URI(external['uri']).host,
        'description' => external['description'],
        'image' => external['thumb'],
        'hash' => post['uri'].split('/').last, # Use post URI as identifier
        'timestamp' => Time.parse(record['createdAt']).to_i * 1000 # Convert to milliseconds
      }
      links << link_data
    end

    # Remove duplicates and sort by timestamp (newest first)
    links.uniq { |l| l['url'] }.sort_by { |l| -l['timestamp'] }
  rescue StandardError
    nil
  end
end
