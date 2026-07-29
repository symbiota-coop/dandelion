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
        if (did = parse_did_from_dns(txt))
          return did
        end
      end

      nil
    rescue StandardError
      nil
    end

    private

    # DIDKit normally fetches handle and did:web documents with Net::HTTP.
    # Keep those requests on public HTTPS destinations and validate redirects.
    def get_response(url, _options = {})
      SsrfFilter.get(url, {
                       scheme_whitelist: %w[https],
                       max_redirects: 3,
                       http_options: { open_timeout: 5, read_timeout: 5 }
                     })
    end
  end
end
