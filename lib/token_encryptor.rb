module TokenEncryptor
  class << self
    def encrypt(data)
      return unless (secret = ENV['SESSION_SECRET'])

      token = encryptor(secret).encrypt_and_sign(data)
      Base64.urlsafe_encode64(token)
    end

    def decrypt(token)
      return unless token && (secret = ENV['SESSION_SECRET'])

      decoded_token = Base64.urlsafe_decode64(token)
      encryptor(secret).decrypt_and_verify(decoded_token)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveSupport::MessageEncryptor::InvalidMessage, ArgumentError
      nil
    end

    private

    def encryptor(secret)
      ActiveSupport::MessageEncryptor.new(secret[0, 32])
    end
  end
end
