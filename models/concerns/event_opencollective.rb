module EventOpenCollective
  extend ActiveSupport::Concern

  # Open Collective statuses that mean money was actually collected.
  # NEW is the initial checkout state (PaymentIntent created, not yet paid).
  # ERROR/CANCELLED/EXPIRED/PROCESSING/PENDING must not complete Dandelion orders.
  COMPLETED_STATUSES = %w[PAID ACTIVE].freeze
  OC_PAGE_SIZE = 100

  class_methods do
    def oc_transactions(oc_slug)
      transactions = []

      query = %{
      query (
        $account: AccountReferenceInput
        $status: [OrderStatus]
        $limit: Int
        $offset: Int
      ) {
        orders(account: $account, status: $status, limit: $limit, offset: $offset) {
          nodes {
            legacyId
            createdAt
            status
            tags
            amount {
              value
              currency
              valueInCents
            }
          }
        }
      }
    }

      conn = Faraday.new(url: 'https://api.opencollective.com/graphql/v2/') do |faraday|
        faraday.request  :url_encoded
        faraday.adapter  Faraday.default_adapter
        faraday.headers['Content-Type'] = 'application/json'
        faraday.headers['Api-Key'] = ENV['OC_API_KEY']
      end

      offset = 0
      loop do
        response = conn.post do |req|
          req.body = {
            query: query,
            variables: {
              account: { slug: oc_slug },
              status: COMPLETED_STATUSES,
              limit: OC_PAGE_SIZE,
              offset: offset
            }
          }.to_json
        end

        j = JSON.parse(response.body)
        nodes = j.dig('data', 'orders', 'nodes') || []
        nodes.each do |item|
          next unless COMPLETED_STATUSES.include?(item['status'])

          currency = item['amount']['currency']
          amount = item['amount']['value']
          secret = Array(item['tags']).select { |tag| tag.starts_with?('dandelion:') }.first
          tx_created_at = Time.parse(item['createdAt'])

          puts [currency, amount, secret, tx_created_at, item['status']]
          transactions << [currency, amount, secret, tx_created_at]
        end

        break if nodes.size < OC_PAGE_SIZE

        offset += OC_PAGE_SIZE
      end

      transactions
    end
  end

  def oc_transactions
    Event.oc_transactions(oc_slug)
  end

  def check_oc_event
    oc_transactions.each do |currency, amount, secret, tx_created_at|
      next unless secret

      @order = orders.find_by(:payment_completed => false, :currency => currency, :value => amount, :oc_secret => secret, :created_at.lt => tx_created_at)
      @order ||= orders.deleted.find_by(:payment_completed => false, :currency => currency, :value => amount, :oc_secret => secret, :created_at.lt => tx_created_at)
      next unless @order

      @order.complete_or_restore(error_context: { order_id: @order.id.to_s })
    end
  end
end
