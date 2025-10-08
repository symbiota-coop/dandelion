module AccountFarcaster
  extend ActiveSupport::Concern

  def farcaster_user
    provider_link = provider_links.find_by(provider: 'Ethereum')
    return unless provider_link

    r = FARQUEST.get('user-by-connected-address', { address: provider_link.provider_uid })
    parsed_response = JSON.parse(r.body)
    parsed_response&.dig('result', 'user')
  rescue JSON::ParserError
    nil
  end

  def farcaster_casts
    f = farcaster_user
    return unless f

    fid = f['fid']
    r = FARQUEST.get('casts', { fid: fid })
    parsed_response = JSON.parse(r.body)
    parsed_response&.dig('result', 'casts')
  rescue JSON::ParserError
    nil
  end

  def farcaster_links
    casts = farcaster_casts
    return unless casts

    links = []
    casts.each do |c|
      next unless c && !c['parentUrl'] && c['embeds'] && c['embeds']['urls']

      c['embeds']['urls'].each do |url|
        og = url&.dig('openGraph')
        next unless og && og['url'] && og['image']

        og['hash'] = c['hash']
        og['timestamp'] = c['timestamp']
        links << og
      end
    end
    links
  end
end
