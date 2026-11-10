# OmniAuth strategy for signing in with Bluesky, using our own ATProto OAuth client
# (AtprotoOAuth), so the callback reaches /auth/atproto/callback as other providers'
# do, and any failure redirects to /auth/failure.
module OmniAuth
  module Strategies
    class Atproto
      include OmniAuth::Strategy

      # The sign-in in progress: its DID, authorization server, state, PKCE verifier and DPoP key
      FLOW_KEY = 'atproto.flow'.freeze

      option :name, 'atproto'

      # Forgets any earlier sign-in before anything can fail, so a failed one never leaves a flow behind
      def request_phase
        session.delete(FLOW_KEY)
        flow, authorization_url = AtprotoOAuth.start(request.params['handle'])
        session[FLOW_KEY] = flow
        redirect authorization_url
      rescue AtprotoOAuth::Error => e
        fail!(e.code, e)
      end

      # The flow is taken out of the session, so it's used once
      def callback_phase
        @identity = AtprotoOAuth.finish(session.delete(FLOW_KEY), request.params)
        super
      rescue AtprotoOAuth::Error => e
        fail!(e.code, e)
      end

      uid { @identity['did'] }

      # pds_host is the authorization server, as the omniauth-atproto gem we used before stored it
      info { { did: @identity['did'], pds_host: @identity['issuer'] } }
    end
  end
end
