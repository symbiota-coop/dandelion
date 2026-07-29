module TokenEncryptor
  class << self
    def encrypt(data)
      return unless (secret = ENV['SESSION_SECRET'])

      encryptor(secret, url_safe: true).encrypt_and_sign(data)
    end

    def decrypt(token)
      return unless token && (secret = ENV['SESSION_SECRET'])

      decrypt_with(encryptor(secret, url_safe: true), token) ||
        decrypt_with(encryptor(secret), token) ||
        decrypt_legacy_base64_token(secret, token)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveSupport::MessageEncryptor::InvalidMessage, ArgumentError
      nil
    end

    private

    def encryptor(secret, **options)
      ActiveSupport::MessageEncryptor.new(secret[0, 32], **options)
    end

    def decrypt_with(encryptor, token)
      encryptor.decrypt_and_verify(token)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveSupport::MessageEncryptor::InvalidMessage, ArgumentError
      nil
    end

    def decrypt_legacy_base64_token(secret, token)
      decoded_token = Base64.urlsafe_decode64(token)
      decrypt_with(encryptor(secret, url_safe: true), decoded_token) ||
        decrypt_with(encryptor(secret), decoded_token)
    rescue ArgumentError
      nil
    end
  end
end
