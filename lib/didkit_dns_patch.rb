require 'didkit'
require 'faraday'
require 'json'

module DIDKit
  class Resolver
    # Override to use Cloudflare DNS-over-HTTPS (works on Render)
    def resolve_handle_by_dns(domain)
      url = "https://cloudflare-dns.com/dns-query?name=_atproto.#{domain}&type=TXT"
      response = Faraday.get(url) do |req|
        req.headers['Accept'] = 'application/dns-json'
      end

      return nil unless response.success?

      data = JSON.parse(response.body)
      answers = data['Answer'] || []

      answers.each do |answer|
        next unless answer['type'] == 16 # TXT record

        txt = answer['data'].to_s.gsub(/\A"|"\z/, '')
        if did = parse_did_from_dns(txt)
          return did
        end
      end

      nil
    rescue StandardError
      nil
    end
  end
end
