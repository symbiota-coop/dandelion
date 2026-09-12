# Sign-In with Ethereum (EIP-4361) via siwe-rb.
#
# The request phase issues a single-use nonce (kept in the session) and renders an
# EIP-4361 message template bound to this site's domain and callback URI. The browser
# substitutes the wallet address, signs the message with personal_sign and POSTs the
# message and signature back. The callback phase parses the message and verifies the
# signature, domain, URI, chain ID, expiry and nonce, so a captured signature cannot be
# replayed, redirected from another site, or used to link a wallet via CSRF.
module OmniAuth
  module Strategies
    class Ethereum
      include OmniAuth::Strategy

      option :name, 'ethereum'
      option :title, 'Sign in with Ethereum'
      option :statement, 'Sign in to Dandelion with your Ethereum account.'
      option :chain_id, 1
      option :expiry, 5 * 60

      SESSION_KEY = 'omniauth.siwe_nonce'.freeze
      ADDRESS_PLACEHOLDER = '0x0000000000000000000000000000000000000000'.freeze

      def request_phase
        nonce = Siwe.generate_nonce
        session[SESSION_KEY] = nonce

        form = OmniAuth::Form.new(title: options.title, url: callback_path)
        form.html(%(<span class="custom_title">#{h(options.title)}</span>))
        form.html(%(<input type="hidden" id="siwe_template" name="siwe_template" value="#{h(message_template(nonce))}" data-placeholder="#{ADDRESS_PLACEHOLDER}" />))
        form.html(%(<input type="hidden" id="siwe_message" name="siwe_message" />))
        form.html(%(<input type="hidden" id="siwe_signature" name="siwe_signature" />))
        form.button 'Sign In'
        form.to_response
      end

      def callback_phase
        # The nonce is consumed whatever happens, so a failed attempt can't be retried with the same message
        nonce = session.delete(SESSION_KEY)
        return fail!(:invalid_request) unless request.post?
        return fail!(:missing_nonce) unless nonce

        message = Siwe::Message.parse(request.params['siwe_message'].to_s)
        message.verify!(
          signature: request.params['siwe_signature'].to_s,
          domain: domain,
          nonce: nonce,
          uri: callback_uri,
          chain_id: options.chain_id
        )
        @address = Siwe::Util.checksum_address(message.address)
        return fail!(:invalid_credentials) unless @address

        super
      rescue Siwe::Error => e
        fail!(e.type, e)
      end

      uid { @address }

      info { { 'nickname' => @address } }

      private

      def message_template(nonce)
        now = Time.now.utc
        Siwe::Message.new(
          domain: domain,
          address: ADDRESS_PLACEHOLDER,
          statement: options.statement,
          uri: callback_uri,
          chain_id: options.chain_id,
          nonce: nonce,
          issued_at: now.iso8601,
          expiration_time: (now + options.expiry).iso8601
        ).prepare_message
      end

      def base_uri
        @base_uri ||= URI(ENV['BASE_URI'] || full_host)
      end

      def domain
        base_uri.port == base_uri.default_port ? base_uri.host : "#{base_uri.host}:#{base_uri.port}"
      end

      def callback_uri
        "#{base_uri.scheme}://#{domain}#{callback_path}"
      end

      def h(str)
        Rack::Utils.escape_html(str)
      end
    end
  end
end
