class StripeTransaction
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :organisation, index: true
  belongs_to :stripe_charge, optional: true, index: true

  field :balance_transaction_id, type: String
  field :created_utc, type: Time
  field :available_on_utc, type: Time
  field :currency, type: String
  field :gross, type: Float
  field :fee, type: Float
  field :net, type: Float
  field :reporting_category, type: String
  field :source_id, type: String
  field :description, type: String
  field :customer_facing_amount, type: Float
  field :customer_facing_currency, type: String
  field :automatic_payout_id, type: String
  field :automatic_payout_effective_at, type: Time

  def self.admin_fields
    {
      organisation_id: :lookup,
      stripe_charge_id: :lookup,
      balance_transaction_id: :text,
      created_utc: :datetime,
      available_on_utc: :datetime,
      currency: :text,
      gross: :number,
      fee: :number,
      net: :number,
      reporting_category: :text,
      source_id: :text,
      description: :text,
      customer_facing_amount: :number,
      customer_facing_currency: :text,
      automatic_payout_id: :text,
      automatic_payout_effective_at: :datetime
    }
  end

  def gross_money
    Money.new(gross * 100, currency)
  end

  def fee_money
    Money.new(fee * 100, currency)
  end

  def net_money
    Money.new(net * 100, currency)
  end

  def self.transfer(organisation, from: nil, to: Date.today - 1)
    unless from
      most_recent_stripe_transaction = organisation.stripe_transactions.order('created_utc desc').first
      from = most_recent_stripe_transaction ? most_recent_stripe_transaction.created_utc.to_date + 1 : Date.today - 2
    end

    puts "transferring charges for #{organisation.slug} from #{from} to #{to}"

    Stripe.api_key = organisation.stripe_sk
    Stripe.api_version = '2020-08-27'

    run = Stripe::Reporting::ReportRun.create({
                                                report_type: 'balance_change_from_activity.itemized.1',
                                                parameters: {
                                                  interval_start: Time.utc(from.year, from.month, from.day).to_i,
                                                  interval_end: Time.utc(to.year, to.month, to.day).to_i
                                                }
                                              })

    until run.result
      puts 'sleeping...'
      sleep 5
      run = Stripe::Reporting::ReportRun.retrieve(run.id)
    end

    uri = URI(run.result.url)
    csv = nil
    Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      request = Net::HTTP::Get.new uri.request_uri
      request.basic_auth organisation.stripe_sk, ''
      response = http.request request
      csv = CSV.parse(response.body.encode('utf-8', invalid: :replace, undef: :replace, replace: '_'), headers: true, header_converters: :symbol)
    end

    csv.each do |transaction|
      transaction = transaction.to_hash.transform_keys(&:to_s)
      t = {}
      t['stripe_charge_id'] = transaction['charge_id']
      %w[balance_transaction_id created_utc available_on_utc currency gross fee net reporting_category source_id description customer_facing_amount customer_facing_currency automatic_payout_id automatic_payout_effective_at].each do |f|
        t[f] = case f
               when 'created_utc', 'available_on_utc', 'automatic_payout_effective_at'
                 "#{transaction[f]} +0000" if transaction[f]
               else
                 transaction[f]
               end
      end
      puts t['created_utc']
      organisation.stripe_transactions.create!(t)
    end
  end
end
