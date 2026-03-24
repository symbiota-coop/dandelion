module TokenVerifier
  class << self
    def generate(data)
      return unless (secret = ENV['SESSION_SECRET'])

      verifier(secret).generate(data)
    end

    def verify(token)
      return unless token && (secret = ENV['SESSION_SECRET'])

      verifier(secret).verified(token) || TokenEncryptor.decrypt(token)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveSupport::MessageEncryptor::InvalidMessage, ArgumentError
      nil
    end

    private

    def verifier(secret)
      ActiveSupport::MessageVerifier.new(secret, digest: 'SHA256')
    end
  end
end
