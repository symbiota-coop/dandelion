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
module OmniAuth
  module Strategies
    class Atproto
      def callback_url
        full_host + callback_path
      end
    end
  end
end
