require_relative '../test_config'

# Crypto payments for an organisation's events: reading the transfers to its address from Blockscout on each chain
# (EvmTransactions.evm_transactions), and completing the order whose amount, its value plus its secret in millionths,
# arrived in its token (OrganisationEvm#check_evm_account)
class OrganisationEvmPaymentsTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  EVM_ADDRESS = '0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed'.freeze
  OTHER_ADDRESS = '0xfb6916095ca1df60bb79ce92ce3ea74c37c5d359'.freeze
  BREAD = '0xa555d5344f6fb6c65da19e403cb4c1ec4a1a5ee3'.freeze # on Gnosis, 18 decimals
  CUSD = '0x765DE816845861e75A25fCA122bb6898B8B1282a'.freeze # on Celo, 18 decimals
  USDC = '0x833589fcd6edb6e08f4c7c32d4f71b54bda02913'.freeze # on Base, 6 decimals

  def blockscout_url(chain, address = EVM_ADDRESS)
    "https://#{chain}.blockscout.com/api/v2/addresses/#{address}/token-transfers"
  end

  # A token transfer as Blockscout v2 lists it: the value in the token's smallest unit, as a string
  def transfer(to:, token:, value:, decimals:)
    { 'to' => { 'hash' => to }, 'token' => { 'address_hash' => token }, 'total' => { 'value' => value, 'decimals' => decimals } }
  end

  # Answers Faraday.get for each chain's URL from responses: { chain => [transfers] }, a status, or an exception to raise
  def blockscout(responses, address = EVM_ADDRESS, &)
    response_class = Struct.new(:status, :body) do
      def success? = status.between?(200, 299)
    end
    responder = lambda do |url|
      chain = %w[gnosis base celo].find { |name| url == blockscout_url(name, address) } || raise("Unexpected Faraday.get for #{url}")
      response = responses.fetch(chain, [])
      raise response if response.is_a?(Exception)
      next response_class.new(response, '') if response.is_a?(Integer)

      response_class.new(200, { 'items' => response }.to_json)
    end
    Faraday.stub(:get, responder, &)
  end

  test "evm_transactions reads the transfers to the address on each chain, in the tokens Dandelion knows, from their value and decimals" do
    transactions = blockscout(
      'gnosis' => [
        # To the address in its checksummed case, which Blockscout gives
        transfer(to: Organisation.evm_checksum_address(EVM_ADDRESS), token: BREAD, value: '20500000000000000000', decimals: '18'),
        # From the address, to someone else
        transfer(to: OTHER_ADDRESS, token: BREAD, value: '1000000000000000000', decimals: '18'),
        # In a token Dandelion doesn't know
        transfer(to: EVM_ADDRESS, token: OTHER_ADDRESS, value: '5000000000000000000', decimals: '18')
      ],
      'base' => Faraday::ConnectionFailed.new('connection refused'),
      # The token's contract address in another case from Dandelion's list
      'celo' => [transfer(to: EVM_ADDRESS, token: CUSD.downcase, value: '10001234000000000000', decimals: '18')]
    ) { Organisation.evm_transactions(EVM_ADDRESS) }

    assert_equal [['BREAD', 20.5], ['CUSD', 10.001234]], transactions
  end

  test "evm_transactions skips a chain whose Blockscout errors or sends what it can't read, and reads the others" do
    reported = []
    transactions = ErrorReporting.stub(:capture_exception, ->(error, **) { reported << error }) do
      blockscout('gnosis' => 503, 'celo' => [{ 'unexpected' => true }],
                 'base' => [transfer(to: EVM_ADDRESS, token: USDC, value: '15000000', decimals: '6')]) do
        Organisation.evm_transactions(EVM_ADDRESS)
      end
    end

    assert_equal [['USDC', 15.0]], transactions
    assert_equal [NoMethodError], reported.map(&:class)
  end

  def create_evm_order(currency: 'USDC', value: 10, evm_secret: '1234')
    order = @event.orders.create!(account: FactoryBot.create(:account), currency: currency, value: value, evm_secret: evm_secret,
                                  payment_completed: false)
    order.tickets.create!(event: @event, account: order.account, ticket_type: @event.ticket_types.first, price: value)
    order
  end

  test 'a crypto order completes when its amount plus its secret arrives in its token, and not for the amount alone or another token' do
    covers_route 'GET /e/:slug/orders/:order_id/payment_completed'
    create_event(prices: [10])
    @organisation.set(evm_address: EVM_ADDRESS)
    order = create_evm_order
    assert_equal BigDecimal('10.001234'), order.evm_value
    path = "/e/#{@event.slug}/orders/#{order.public_id}/payment_completed"

    blockscout('base' => [transfer(to: EVM_ADDRESS, token: USDC, value: '10000000', decimals: '6')],
               'celo' => [transfer(to: EVM_ADDRESS, token: CUSD, value: '10001234000000000000', decimals: '18')]) { get path }
    assert_equal false, JSON.parse(last_response.body)['payment_completed']
    refute Order.find(order.id).payment_completed

    blockscout('base' => [transfer(to: EVM_ADDRESS, token: USDC, value: '10001234', decimals: '6')]) { get path }
    assert_equal true, JSON.parse(last_response.body)['payment_completed']
    assert Order.find(order.id).payment_completed
    assert order.tickets.first.reload.payment_completed
  end

  test 'a crypto order deleted when its hold ran out is restored and completed, with its tickets, when its payment arrives' do
    create_event(prices: [10])
    @organisation.set(evm_address: EVM_ADDRESS)
    order = create_evm_order
    ticket = order.tickets.first
    order.set(created_at: (Order::UNPAID_HOLD + 1.minute).ago)
    Order.destroy_expired_holds
    assert_nil Order.find(order.id)

    blockscout('base' => [transfer(to: EVM_ADDRESS, token: USDC, value: '10001234', decimals: '6')]) do
      Organisation.find(@organisation.id).check_evm_account
    end

    order = Order.find(order.id)
    assert order.payment_completed
    assert order.restored
    assert Ticket.find(ticket.id).payment_completed
  end
end
