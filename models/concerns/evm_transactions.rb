require 'digest/keccak'

module EvmTransactions
  extend ActiveSupport::Concern

  EVM_ADDRESS = /\A0x[0-9a-f]{40}\z/i

  included do
    before_validation :clean_evm_address
    validates_format_of :evm_address, with: EVM_ADDRESS, allow_nil: true
  end

  # Strips the address and, if it's in mixed case, checks its EIP-55 checksum: a mistyped character almost always
  # breaks it, and payments would go to the mistyped address. Wallets copy addresses in mixed case; all lower or all
  # upper case has no checksum to check
  def clean_evm_address
    self.evm_address = evm_address&.strip
    return unless evm_address&.match?(EVM_ADDRESS)

    hex = evm_address.delete_prefix('0x')
    return if [hex.downcase, hex.upcase].include?(hex) || evm_address == self.class.evm_checksum_address(evm_address)

    errors.add(:evm_address, "doesn't match its checksum, so a character may be mistyped: copy it from your wallet again")
  end

  class_methods do
    # The address with the EIP-55 checksum in its letters' case: each hex letter is upper case where the matching
    # nibble of the Keccak-256 hash of the lower-case address is 8 or more
    def evm_checksum_address(address)
      hex = address.delete_prefix('0x').downcase
      hash = Digest::Keccak.new(256).hexdigest(hex)
      "0x#{hex.chars.each_with_index.map { |char, i| hash[i].to_i(16) >= 8 ? char.upcase : char }.join}"
    end

    def evm_transactions(evm_address)
      transactions = []

      # Blockscout v2
      [
        "https://gnosis.blockscout.com/api/v2/addresses/#{evm_address}/token-transfers",
        "https://base.blockscout.com/api/v2/addresses/#{evm_address}/token-transfers",
        "https://celo.blockscout.com/api/v2/addresses/#{evm_address}/token-transfers"
      ].each do |url|
        puts url
        response = begin
          Faraday.get(url)
        rescue Faraday::Error
          nil
        end
        next unless response&.success?

        j = JSON.parse(response.body)
        j['items'].each do |item|
          puts item['block_hash']

          to = item['to']['hash']
          unless to.downcase == evm_address.downcase
            # puts 'transaction is not to the address'
            next
          end

          token_address = item['token']['address_hash']
          unless token_address
            # puts 'token address is missing'
            next
          end

          token_find = Token.by_contract_address.find { |k, _v| k.downcase == token_address.downcase }
          unless token_find
            # puts 'token not found'
            next
          end

          token = token_find[1]
          unless token
            # puts 'token is missing'
            next
          end

          amount = item['total']['value'].to_f / (10**item['total']['decimals'].to_i)
          unless amount
            # puts 'amount is missing'
            next
          end

          puts [token, amount]
          transactions << [token, amount]
        end
      rescue StandardError => e
        ErrorReporting.capture_exception(e)
      end

      transactions
    end
  end

  def evm_transactions
    self.class.evm_transactions(evm_address)
  end
end
