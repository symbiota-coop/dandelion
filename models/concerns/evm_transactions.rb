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
          to = item['to']['hash']
          next unless to.downcase == evm_address.downcase

          token_address = item['token']['address']
          next unless token_address

          token_find = Token.by_contract_address.find { |k, _v| k.downcase == token_address.downcase }
          next unless token_find

          token = token_find[1]
          next unless token

          amount = item['total']['value'].to_f / (10**item['total']['decimals'].to_i)
          next unless amount

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
