require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class EventOpenCollectiveTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  def oc_node(status:, secret:, amount: 15, currency: 'GBP', created_at: Time.now)
    {
      'legacyId' => 12_345,
      'createdAt' => created_at.iso8601,
      'status' => status,
      'tags' => [secret].compact,
      'amount' => { 'value' => amount, 'currency' => currency, 'valueInCents' => (amount * 100).to_i }
    }
  end

  def stub_oc_orders(*pages)
    requests = []
    page_index = 0
    conn = Object.new
    conn.define_singleton_method(:post) do |&block|
      req = Object.new
      req.define_singleton_method(:body=) { |body| requests << JSON.parse(body) }
      block.call(req)
      nodes = pages[page_index] || []
      page_index += 1
      Struct.new(:body).new({ 'data' => { 'orders' => { 'nodes' => nodes } } }.to_json)
    end

    Faraday.stub(:new, proc { conn }) { yield requests }
    requests
  end

  def create_oc_event
    create_organisation(oc_slug: 'south-west-grain-network')
    create_event(oc_slug: 'swgn-agm-2026', prices: [15])
  end

  def create_incomplete_oc_order(secret:, value: 15, created_at: 1.hour.ago)
    order = @event.orders.create!(
      account: FactoryBot.create(:account),
      currency: @event.currency,
      value: value,
      payment_completed: false,
      oc_secret: secret,
      original_description: 'OC test order'
    )
    order.set(created_at: created_at)
    order
  end

  test 'oc_transactions requests only PAID and ACTIVE Open Collective orders' do
    requests = stub_oc_orders([]) do
      Event.oc_transactions('south-west-grain-network')
    end

    assert_equal 1, requests.size
    assert_equal EventOpenCollective::COMPLETED_STATUSES, requests.first.dig('variables', 'status')
    assert_includes requests.first['query'], '$status: [OrderStatus]'
    assert_includes requests.first['query'], 'status: $status'
  end

  test 'oc_transactions ignores unpaid Open Collective statuses even if the API returns them' do
    paid_at = Time.parse('2026-09-01T12:00:00Z')
    stub_oc_orders([
                     oc_node(status: 'NEW', secret: 'dandelion:newxx'),
                     oc_node(status: 'ERROR', secret: 'dandelion:error'),
                     oc_node(status: 'CANCELLED', secret: 'dandelion:cancl'),
                     oc_node(status: 'PROCESSING', secret: 'dandelion:procx'),
                     oc_node(status: 'PENDING', secret: 'dandelion:pendx'),
                     oc_node(status: 'PAID', secret: 'dandelion:paidx', created_at: paid_at),
                     oc_node(status: 'ACTIVE', secret: 'dandelion:activ', amount: 10, created_at: paid_at)
                   ]) do
      transactions = Event.oc_transactions('south-west-grain-network')
      secrets = transactions.map { |(_currency, _amount, secret, _created_at)| secret }
      assert_equal ['dandelion:paidx', 'dandelion:activ'], secrets
      assert_equal ['GBP', 15, 'dandelion:paidx', paid_at], transactions.first
    end
  end

  test 'check_oc_event completes a pending order when Open Collective has a matching paid contribution' do
    create_oc_event
    order = create_incomplete_oc_order(secret: 'dandelion:g6m6t')

    @event.stub(:oc_transactions, [['GBP', 15, 'dandelion:g6m6t', Time.now]]) do
      @event.check_oc_event
    end

    assert order.reload.payment_completed?
  end

  test 'check_oc_event does not complete a pending order from an unpaid Open Collective contribution' do
    create_oc_event
    unpaid = create_incomplete_oc_order(secret: 'dandelion:7h0vi')
    paid = create_incomplete_oc_order(secret: 'dandelion:g6m6t')

    stub_oc_orders([
                     oc_node(status: 'NEW', secret: 'dandelion:7h0vi'),
                     oc_node(status: 'PAID', secret: 'dandelion:g6m6t')
                   ]) do
      @event.check_oc_event
    end

    refute unpaid.reload.payment_completed?
    assert paid.reload.payment_completed?
  end
end
