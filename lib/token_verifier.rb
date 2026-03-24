module TokenVerifier
  class << self
    def generate(data)
      return unless (secret = ENV['SESSION_SECRET'])

      token = verifier(secret).generate(data)
      Base64.urlsafe_encode64(token)
    end

    def verify(token)
      return unless token && (secret = ENV['SESSION_SECRET'])

      decoded_token = Base64.urlsafe_decode64(token)
      verifier(secret).verified(decoded_token) || TokenEncryptor.decrypt(token)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveSupport::MessageEncryptor::InvalidMessage, ArgumentError
      nil
    end

    private

    def verifier(secret)
      ActiveSupport::MessageVerifier.new(secret, digest: 'SHA256')
    end
  end
end
