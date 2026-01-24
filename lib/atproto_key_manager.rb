require 'openssl'
require 'json'
require 'base64'

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

      point = key.public_key
      bn = point.to_bn(:uncompressed)
      bytes = bn.to_s(2)

      x = bytes[1, 32]
      y = bytes[33, 32]

      {
        kty: 'EC',
        crv: 'P-256',
        x: base64url_encode(x),
        y: base64url_encode(y),
        use: 'sig',
        alg: 'ES256',
        kid: generate_kid(key)
      }
    end

    def generate_kid(key)
      return nil unless key

      jwk = build_jwk_without_kid(key)
      thumbprint_input = JSON.generate({
                                         crv: jwk[:crv],
                                         kty: jwk[:kty],
                                         x: jwk[:x],
                                         y: jwk[:y]
                                       })
      base64url_encode(OpenSSL::Digest::SHA256.digest(thumbprint_input))
    end

    def build_jwk_without_kid(key)
      return nil unless key

      point = key.public_key
      bn = point.to_bn(:uncompressed)
      bytes = bn.to_s(2)

      x = bytes[1, 32]
      y = bytes[33, 32]

      {
        kty: 'EC',
        crv: 'P-256',
        x: base64url_encode(x),
        y: base64url_encode(y)
      }
    end

    def base64url_encode(data)
      Base64.urlsafe_encode64(data, padding: false)
    end

    def client_metadata
      base_uri = ENV['BASE_URI']
      {
        client_id: "#{base_uri}/oauth-client-metadata.json",
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
  end
end
