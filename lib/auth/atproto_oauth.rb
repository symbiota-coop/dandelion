# Sign in with Bluesky: an ATProto OAuth client (https://atproto.com/specs/oauth), used by
# OmniAuth::Strategies::Atproto. Dandelion is a confidential client: its client metadata
# (/atproto/oauth-client-metadata.json) publishes AtprotoKeyManager's public key, and it
# authenticates to authorization servers with private_key_jwt.
#
# start: resolve the handle (or DID) to its DID, the DID's PDS, and the authorization
# server the PDS names; push the authorization request (PAR, which servers require),
# with PKCE and a DPoP proof; and return the flow to keep in the session, and the URL to
# send the person to.
#
# finish: check the callback is for that flow (state) and from that server (iss, RFC
# 9207), exchange the code with the same DPoP key, and check the token's DID (sub) is the
# one the handle resolved to, and that the DID's own PDS names that server as its
# authorization server, so no server can vouch for someone else's DID.
#
# Every request goes through SsrfFilter, as the URLs come from documents anyone can
# publish (DIDKit's own requests too: lib/patches/didkit_dns.rb).
module AtprotoOAuth
  class Error < StandardError
    attr_reader :code

    # code becomes the message key of /auth/failure
    def initialize(code, message = code.to_s)
      @code = code
      super(message)
    end
  end

  SCOPE = 'atproto'.freeze
  HTTP = { scheme_whitelist: %w[https], max_redirects: 3, http_options: { open_timeout: 5, read_timeout: 5 } }.freeze
  # OAuth endpoints are never redirected to
  POST_HTTP = HTTP.merge(max_redirects: 0).freeze
  ENDPOINTS = %w[authorization_endpoint token_endpoint pushed_authorization_request_endpoint].freeze
  HANDLE = /\A([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?\z/
  DID = /\Adid:(plc|web):[a-zA-Z0-9._:%-]{1,2000}\z/
  FLOW_FIELDS = %w[did issuer token_endpoint state code_verifier dpop_key].freeze

  class << self
    # Returns [flow, authorization URL]
    def start(identifier)
      raise Error.new(:not_configured, 'ATPROTO_PRIVATE_KEY_PEM is not set') unless AtprotoKeyManager.current_private_key

      did = resolve_identifier(identifier)
      issuer = authorization_server_for(did)
      metadata = authorization_server_metadata(issuer)

      dpop_key = OpenSSL::PKey::EC.generate('prime256v1')
      state = SecureRandom.urlsafe_base64(32)
      code_verifier = SecureRandom.urlsafe_base64(48)
      body, dpop_nonce = token_request(metadata['pushed_authorization_request_endpoint'], issuer, dpop_key, nil, :invalid_auth_server,
                                       response_type: 'code',
                                       redirect_uri: AtprotoKeyManager.redirect_uri,
                                       scope: SCOPE,
                                       state: state,
                                       code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(code_verifier), padding: false),
                                       code_challenge_method: 'S256',
                                       login_hint: identifier_hint(identifier))
      request_uri = body['request_uri']
      raise Error.new(:invalid_auth_server, 'PAR response has no request_uri') unless request_uri.is_a?(String) && request_uri.present?

      flow = {
        'did' => did, 'issuer' => issuer, 'token_endpoint' => metadata['token_endpoint'],
        'state' => state, 'code_verifier' => code_verifier, 'dpop_key' => dpop_key.to_pem, 'dpop_nonce' => dpop_nonce
      }
      # Added to any query the endpoint already has (RFC 6749 3.1)
      authorization_url = URI.parse(metadata['authorization_endpoint'])
      authorization_url.query = URI.encode_www_form(
        URI.decode_www_form(authorization_url.query.to_s) + [['client_id', AtprotoKeyManager.client_id], ['request_uri', request_uri]]
      )
      [flow, authorization_url.to_s]
    rescue Error
      raise
    rescue StandardError => e # SsrfFilter, DIDKit, JSON, OpenSSL, timeouts
      raise Error.new(:invalid_auth_server, "#{e.class}: #{e.message}")
    end

    # Returns { 'did' => ..., 'issuer' => ... }
    def finish(flow, params)
      raise Error.new(:missing_did, 'No sign-in in progress') unless complete_flow?(flow)
      raise Error.new(:csrf_detected, 'State is not for this sign-in') unless secure_equal?(params['state'], flow['state'])
      raise Error.new(:invalid_issuer, 'Callback iss is not the expected issuer') unless secure_equal?(params['iss'], flow['issuer'])
      raise Error.new(:access_denied, params['error'].to_s) if params['error'].present?
      raise Error.new(:invalid_credentials, 'Callback has no code') unless params['code'].is_a?(String) && params['code'].present?

      token, = token_request(flow['token_endpoint'], flow['issuer'], OpenSSL::PKey::EC.new(flow['dpop_key']), flow['dpop_nonce'], :invalid_credentials,
                             grant_type: 'authorization_code',
                             code: params['code'],
                             redirect_uri: AtprotoKeyManager.redirect_uri,
                             code_verifier: flow['code_verifier'])
      verify_token!(token, flow)
      { 'did' => flow['did'], 'issuer' => flow['issuer'] }
    rescue Error
      raise
    rescue StandardError => e
      raise Error.new(:invalid_credentials, "#{e.class}: #{e.message}")
    end

    def complete_flow?(flow)
      flow.is_a?(Hash) && FLOW_FIELDS.all? { |key| flow[key].is_a?(String) && flow[key].present? }
    end

    # The authorization server the DID's own PDS names, from its DID document and the PDS's protected-resource metadata
    def authorization_server_for(did)
      pds = DIDKit::Resolver.new.resolve_did(did)&.pds_endpoint.to_s
      raise Error.new(:missing_pds, "#{did} has no PDS") unless https_url?(pds)

      issuer = get_json("#{pds.chomp('/')}/.well-known/oauth-protected-resource").dig('authorization_servers', 0).to_s
      raise Error.new(:invalid_auth_server, "#{pds} names no authorization server") unless https_url?(issuer)

      issuer
    end

    private

    def resolve_identifier(identifier)
      identifier = identifier.to_s.strip.delete_prefix('@')
      return identifier if identifier.match?(DID)

      handle = identifier.downcase
      raise Error.new(:invalid_handle, 'Not a handle or DID') unless handle.match?(HANDLE)

      did = DIDKit::Resolver.new.resolve_handle(handle)&.to_s
      raise Error.new(:unknown_handle, "#{handle} did not resolve to a DID") unless did&.match?(DID)

      did
    end

    def identifier_hint(identifier)
      identifier.to_s.strip.delete_prefix('@')
    end

    def authorization_server_metadata(issuer)
      metadata = get_json("#{issuer}/.well-known/oauth-authorization-server")
      raise Error.new(:invalid_auth_server, 'Metadata issuer mismatch') unless metadata['issuer'] == issuer

      ENDPOINTS.each do |field|
        raise Error.new(:invalid_auth_server, "Metadata has no https #{field}") unless https_url?(metadata[field])
      end
      metadata
    end

    # POSTs to a PAR or token endpoint, as the client (private_key_jwt) and with a DPoP proof. Servers ask for a
    # nonce by refusing the first request with use_dpop_nonce, so that's retried once with it. Returns the
    # response's JSON and the latest nonce, or raises failure
    def token_request(url, issuer, dpop_key, dpop_nonce, failure, form)
      2.times do |attempt|
        params = form.merge(
          client_id: AtprotoKeyManager.client_id,
          client_assertion_type: 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer',
          client_assertion: client_assertion(issuer)
        )
        response = SsrfFilter.post(url, POST_HTTP.merge(
                                          headers: {
                                            'Content-Type' => 'application/x-www-form-urlencoded',
                                            'Accept' => 'application/json',
                                            'DPoP' => dpop_proof(dpop_key, 'POST', url, dpop_nonce)
                                          },
                                          body: URI.encode_www_form(params)
                                        ))
        dpop_nonce = response['DPoP-Nonce'] if response['DPoP-Nonce'].present?
        body = parse_json(response.body)
        return [body, dpop_nonce] if response.is_a?(Net::HTTPSuccess)
        next if attempt.zero? && body['error'] == 'use_dpop_nonce' && response['DPoP-Nonce'].present?

        raise Error.new(failure, "#{url} returned #{response.code}: #{body['error']} #{body['error_description']}".strip)
      end
    end

    def verify_token!(token, flow)
      raise Error.new(:invalid_credentials, 'Token is not DPoP-bound') unless token['token_type'].to_s.casecmp?('DPoP')
      raise Error.new(:invalid_credentials, 'Token lacks the atproto scope') unless token['scope'].to_s.split.include?(SCOPE)

      sub = token['sub']
      raise Error.new(:invalid_did, 'Token sub is not the DID for this sign-in') unless sub.is_a?(String) && sub == flow['did']

      begin
        did_issuer = authorization_server_for(sub)
      rescue StandardError => e
        raise Error.new(:invalid_issuer, "Could not verify the DID's authorization server: #{e.class}")
      end
      raise Error.new(:invalid_issuer, "Token issuer is not the DID's authorization server") unless did_issuer == flow['issuer']
    end

    def client_assertion(audience)
      now = Time.now.to_i
      claims = { iss: AtprotoKeyManager.client_id, sub: AtprotoKeyManager.client_id, aud: audience, jti: SecureRandom.uuid, iat: now, exp: now + 60 }
      JWT.encode(claims, AtprotoKeyManager.current_private_key, 'ES256', { kid: AtprotoKeyManager.current_jwk[:kid] })
    end

    # htu is the URL without its query and fragment (RFC 9449 4.2)
    def dpop_proof(key, method, url, nonce)
      htu = URI.parse(url).tap { |uri| uri.query = uri.fragment = nil }.to_s
      claims = { jti: SecureRandom.uuid, htm: method, htu: htu, iat: Time.now.to_i }
      claims[:nonce] = nonce if nonce
      JWT.encode(claims, key, 'ES256', { typ: 'dpop+jwt', jwk: JWT::JWK.new(key).export.slice(:kty, :crv, :x, :y) })
    end

    def get_json(url)
      response = SsrfFilter.get(url, HTTP)
      raise Error.new(:invalid_auth_server, "#{url} returned #{response.code}") unless response.is_a?(Net::HTTPSuccess)

      parse_json(response.body)
    end

    def parse_json(body)
      json = JSON.parse(body.to_s)
      json.is_a?(Hash) ? json : {}
    rescue JSON::ParserError
      {}
    end

    def https_url?(url)
      uri = URI.parse(url.to_s)
      uri.is_a?(URI::HTTPS) && uri.host.present?
    rescue URI::InvalidURIError
      false
    end

    def secure_equal?(given, expected)
      given.is_a?(String) && expected.is_a?(String) && ActiveSupport::SecurityUtils.secure_compare(given, expected)
    end
  end
end
