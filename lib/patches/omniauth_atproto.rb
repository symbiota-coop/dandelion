# Monkey patch to fix callback_url - exclude handle param from redirect_uri
# and block SSRF via attacker-controlled PDS / auth-server discovery URLs.
module OmniAuth
  module Strategies
    class Atproto
      DISCOVERY_HTTP = {
        scheme_whitelist: %w[https],
        max_redirects: 3,
        http_options: { open_timeout: 5, read_timeout: 5 }
      }.freeze

      def callback_url
        full_host + callback_path
      end

      def self.get_authorization_server(pds_endpoint)
        response = SsrfFilter.get("#{pds_endpoint}/.well-known/oauth-protected-resource", DISCOVERY_HTTP)

        unless response.is_a?(Net::HTTPSuccess)
          raise SsrfFilter::Error, "Failed to get PDS authorization server: #{response.code}"
        end

        result = JSON.parse(response.body)
        auth_server = result.dig('authorization_servers', 0)
        raise SsrfFilter::Error, 'No authorization server found in response' unless auth_server

        auth_server
      end

      def self.get_authorization_data(issuer)
        response = SsrfFilter.get("#{issuer}/.well-known/oauth-authorization-server", DISCOVERY_HTTP)

        unless response.is_a?(Net::HTTPSuccess)
          raise SsrfFilter::Error, "Failed to get authorization server metadata: #{response.code}"
        end

        result = JSON.parse(response.body)
        raise SsrfFilter::Error, 'Invalid metadata - issuer mismatch' unless result['issuer'] == issuer

        # we cannot keep everything in session (cookie overflow error)
        fields = %w[issuer authorization_endpoint token_endpoint]
        result.select { |k, _v| fields.include?(k) }
      end
    end
  end
end

# atproto_client normally sends token and API requests with Net::HTTP. Filter
# the actual connection so metadata cannot point the server at a private host.
module AtProto
  class Request
    SSRF_HTTP = {
      scheme_whitelist: %w[https],
      max_redirects: 0,
      http_options: { open_timeout: 5, read_timeout: 5 }
    }.freeze

    def run
      request_options = SSRF_HTTP.merge(
        headers: {
          'Content-Type' => 'application/json',
          'Accept' => 'application/json'
        }.merge(headers),
        body: body
      )
      response = SsrfFilter.public_send(method, uri.to_s, request_options)
      handle_response(response)
    end
  end
end
