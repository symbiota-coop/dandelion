module EventOpenCollective
  extend ActiveSupport::Concern

  class_methods do
    def oc_transactions(oc_slug)
      transactions = []

      query = %{
      query (
        $account: AccountReferenceInput
      ) {
        orders(account: $account) {
          nodes {
            legacyId
            createdAt
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

      variables = { account: { slug: oc_slug } }

      conn = Faraday.new(url: 'https://api.opencollective.com/graphql/v2/') do |faraday|
        faraday.request  :url_encoded
        faraday.adapter  Faraday.default_adapter
        faraday.headers['Content-Type'] = 'application/json'
        faraday.headers['Api-Key'] = ENV['OC_API_KEY']
      end

      response = conn.post do |req|
        req.body = {
          query: query,
          variables: variables
        }.to_json
      end

      j = JSON.parse(response.body)
      j['data']['orders']['nodes'].each do |item|
        currency = item['amount']['currency']
        amount = item['amount']['value']
        secret = item['tags'].select { |tag| tag.starts_with?('dandelion:') }.first
        tx_created_at = Time.parse(item['createdAt'])

        puts [currency, amount, secret, tx_created_at]
        transactions << [currency, amount, secret, tx_created_at]
      end

      transactions
    end
  end

  def oc_transactions
    Event.oc_transactions(oc_slug)
  end

  def check_oc_event
    oc_transactions.each do |currency, amount, secret, tx_created_at|
      if (@order = Order.find_by(:payment_completed.ne => true, :currency => currency, :value => amount, :oc_secret => secret, :created_at.lt => tx_created_at))
        @order.payment_completed!
        @order.send_tickets
        @order.create_order_notification
      elsif (@order = Order.deleted.find_by(:payment_completed.ne => true, :currency => currency, :value => amount, :oc_secret => secret, :created_at.lt => tx_created_at))
        begin
          @order.restore_and_complete
          # raise Order::Restored
        rescue StandardError => e
          Airbrake.notify(e, order: @order)
        end
      end
    end
  end
end
