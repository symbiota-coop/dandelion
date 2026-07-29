module TokenVerifier
  class << self
    def generate(data, expires_in: nil, purpose: nil)
      return unless (secret = ENV['SESSION_SECRET'])

      options = {}
      options[:expires_in] = expires_in if expires_in
      options[:purpose] = purpose if purpose

      verifier(secret, url_safe: true).generate(data, **options)
    end

    def verify(token, purpose: nil)
      return unless token && (secret = ENV['SESSION_SECRET'])

      if purpose
        verify_with(verifier(secret, url_safe: true), token, purpose:) ||
          verify_with(verifier(secret), token, purpose:)
      else
        verify_with(verifier(secret, url_safe: true), token) ||
          verify_with(verifier(secret), token) ||
          verify_legacy_base64_token(secret, token) ||
          TokenEncryptor.decrypt(token)
      end
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveSupport::MessageEncryptor::InvalidMessage, ArgumentError
      nil
    end

    private

    def verifier(secret, **)
      ActiveSupport::MessageVerifier.new(secret, digest: 'SHA256', **)
    end

    def verify_with(verifier, token, purpose: nil)
      if purpose
        verifier.verified(token, purpose:)
      else
        verifier.verified(token)
      end
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ArgumentError
      nil
    end

    def verify_legacy_base64_token(secret, token)
      decoded_token = Base64.urlsafe_decode64(token)
      verify_with(verifier(secret, url_safe: true), decoded_token) ||
        verify_with(verifier(secret), decoded_token)
    rescue ArgumentError, ActiveSupport::MessageVerifier::InvalidSignature
      nil
    end
  end
end
