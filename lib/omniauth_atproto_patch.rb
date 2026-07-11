# Custom setup proc for omniauth-atproto that supports GET requests
# The original gem only checks rack.request.form_hash (POST), this adds query string parsing
module AtprotoSetup
  def self.setup_proc
    lambda do |env|
      session = env['rack.session']

      # Check form_hash (POST) first, then parse query string (GET)
      handle = env['rack.request.form_hash']&.dig('handle')
      unless handle
        query_string = env['QUERY_STRING'] || ''
        query_params = Rack::Utils.parse_query(query_string)
        handle = query_params['handle']
      end

      if handle
        begin
          resolver = DIDKit::Resolver.new
          did = resolver.resolve_handle(handle)

          unless did
            return env['omniauth.strategy'].fail!(:unknown_handle,
                                                  OmniAuth::Error.new(
                                                    'Handle parameter did not resolve to a did'
                                                  ))
          end

          endpoint = resolver.resolve_did(did).pds_endpoint
          auth_server = OmniAuth::Strategies::Atproto.get_authorization_server(endpoint)
          session['authorization_info'] = authorization_info = OmniAuth::Strategies::Atproto.get_authorization_data(auth_server)
        rescue SsrfFilter::Error => e
          return env['omniauth.strategy'].fail!(:invalid_auth_server,
                                                OmniAuth::Error.new(e.message))
        end
      end

      if authorization_info ||= session.delete('authorization_info')
        env['omniauth.strategy'].options['client_options']['site'] = authorization_info['issuer']
        env['omniauth.strategy'].options['client_options']['authorize_url'] =
          authorization_info['authorization_endpoint']
        env['omniauth.strategy'].options['client_options']['token_url'] = authorization_info['token_endpoint']
      end
    end
  end
end

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
