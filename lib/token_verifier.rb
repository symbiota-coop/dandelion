module TokenVerifier
  class << self
    def generate(data)
      return unless (secret = ENV['SESSION_SECRET'])

      verifier(secret, url_safe: true).generate(data)
    end

    def verify(token)
      return unless token && (secret = ENV['SESSION_SECRET'])

      verify_with(verifier(secret, url_safe: true), token) ||
        verify_with(verifier(secret), token) ||
        verify_legacy_base64_token(secret, token) ||
        TokenEncryptor.decrypt(token)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveSupport::MessageEncryptor::InvalidMessage, ArgumentError
      nil
    end

    private

    def verifier(secret, **)
      ActiveSupport::MessageVerifier.new(secret, digest: 'SHA256', **)
    end

    def verify_with(verifier, token)
      verifier.verified(token)
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
