require 'jwt'
require 'openssl'

class AtprotoKeyManager
  class << self
    def current_private_key
      @current_private_key ||= if ENV['ATPROTO_PRIVATE_KEY_PEM']
                                 pem = ENV['ATPROTO_PRIVATE_KEY_PEM'].gsub('\\n', "\n")
                                 OpenSSL::PKey::EC.new(pem)
                               end
    end

    def current_jwk
      return nil unless current_private_key

      @current_jwk ||= build_jwk(current_private_key)
    end

    def build_jwk(key)
      return nil unless key

      jwk = JWT::JWK::EC.new(key, nil, kid_generator: JWT::JWK::Thumbprint)
      jwk.export.merge(use: 'sig', alg: 'ES256')
    end

    def client_metadata
      base_uri = ENV['BASE_URI']
      {
        client_id: "#{base_uri}/atproto/oauth-client-metadata.json",
        application_type: 'web',
        client_name: ENV['APP_NAME'] || 'Dandelion',
        client_uri: base_uri,
        dpop_bound_access_tokens: true,
        grant_types: %w[authorization_code refresh_token],
        redirect_uris: ["#{base_uri}/auth/atproto/callback"],
        response_types: ['code'],
        scope: 'atproto',
        token_endpoint_auth_method: 'private_key_jwt',
        token_endpoint_auth_signing_alg: 'ES256',
        jwks: {
          keys: [current_jwk]
        }
      }
    end

    def generate_keys
      pem = OpenSSL::PKey::EC.generate('prime256v1').to_pem

      puts 'Generated new ES256 keypair for AT Protocol OAuth'
      puts ''
      puts 'Add this to your environment variables:'
      puts ''
      puts 'ATPROTO_PRIVATE_KEY_PEM='
      puts pem.gsub("\n", '\\n')
      puts ''
      puts 'Or as a multi-line value (for .env files that support it):'
      puts ''
      puts "ATPROTO_PRIVATE_KEY_PEM=\"#{pem.chomp}\""
    end
  end
end
