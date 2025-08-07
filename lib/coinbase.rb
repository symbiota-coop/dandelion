require 'faraday'
require 'openssl'
require 'json'

module Coinbase
  API_URL = 'https://api.commerce.coinbase.com'.freeze

  class Client
    def initialize(api_key)
      @api_key = api_key
    end

    def create_charge(params)
      response = connection.post('charges') do |req|
        req.body = params.to_json
      end
      JSON.parse(response.body)
    end

    def list_charges
      charges = []
      url = 'charges'
      loop do
        response = connection.get(url)
        data = JSON.parse(response.body)
        charges.concat(data['data'])
        break unless data['pagination'] && data['pagination']['next_uri']
        url = data['pagination']['next_uri']
      end
      charges
    end

    private

    def connection
      @connection ||= Faraday.new(
        url: API_URL,
        headers: {
          'Content-Type' => 'application/json',
          'X-CC-Api-Key' => @api_key,
          'X-CC-Version' => '2018-03-22'
        }
      )
    end
  end

  class Webhook
    class SignatureVerificationError < StandardError; end

    def self.construct_event(payload, sig_header, secret)
      raise SignatureVerificationError, 'Signature header is missing' if sig_header.nil? || sig_header.empty?

      unless verify_signature(payload, sig_header, secret)
        raise SignatureVerificationError, 'Signature verification failed'
      end

      JSON.parse(payload, object_class: OpenStruct)
    end

    def self.verify_signature(payload, sig_header, secret)
      digest = OpenSSL::Digest.new('sha256')
      computed_sig = OpenSSL::HMAC.hexdigest(digest, secret, payload)
      Rack::Utils.secure_compare(computed_sig, sig_header)
    end
  end
end
