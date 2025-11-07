module EvmTransactions
  extend ActiveSupport::Concern

  class_methods do
    def evm_transactions(evm_address)
      transactions = []
      agent = Mechanize.new

      # Blockscout v2
      [
        "https://optimism.blockscout.com/api/v2/addresses/#{evm_address}/token-transfers",
        "https://gnosis.blockscout.com/api/v2/addresses/#{evm_address}/token-transfers",
        "https://base.blockscout.com/api/v2/addresses/#{evm_address}/token-transfers",
        "https://arbitrum.blockscout.com/api/v2/addresses/#{evm_address}/token-transfers",
        "https://celo.blockscout.com/api/v2/addresses/#{evm_address}/token-transfers"
      ].each do |url|
        puts url
        page = begin; agent.get(url); rescue Mechanize::ResponseCodeError; end
        next unless page

        j = JSON.parse(page.body)
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
        Honeybadger.notify(e)
      end

      transactions
    end
  end

  def evm_transactions
    self.class.evm_transactions(evm_address)
  end
end
