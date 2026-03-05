module TokenEncryptor
  class << self
    def encrypt(data)
      return unless (secret = ENV['SESSION_SECRET'])

      crypt = ActiveSupport::MessageEncryptor.new(secret[0, 32])
      token = crypt.encrypt_and_sign(data)
      Base64.urlsafe_encode64(token)
    end

    def decrypt(token)
      return unless token && (secret = ENV['SESSION_SECRET'])

      decoded_token = Base64.urlsafe_decode64(token)
      crypt = ActiveSupport::MessageEncryptor.new(secret[0, 32])
      crypt.decrypt_and_verify(decoded_token)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveSupport::MessageEncryptor::InvalidMessage, ArgumentError
      nil
    end
  end
end
