class StripeCharge
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :organisation
  belongs_to_without_parent_validation :event, optional: true
  belongs_to_without_parent_validation :order, optional: true
  belongs_to_without_parent_validation :account, optional: true

  has_many :stripe_transactions

  field :amount, type: Integer
  field :application_fee, type: String
  field :application_fee_amount, type: Integer
  field :balance_transaction, type: String
  field :created, type: Time
  field :currency, type: String
  field :customer, type: String
  field :description, type: String
  field :destination, type: String
  field :payment_intent, type: String
  field :de_donation_revenue, type: Float
  field :de_ticket_revenue, type: Float
  field :de_discounted_ticket_revenue, type: Float
  field :de_percentage_discount, type: Float
  field :de_percentage_discount_monthly_donor, type: Float
  field :de_credit_applied, type: Float
  field :de_fixed_discount_applied, type: Float
  field :balance_float, type: Float
  field :fees_float, type: Float

  before_validation do
    self.balance_float = 0 unless balance_float
    self.fees_float = 0 unless fees_float
  end

  def summary
    Money.new(amount, currency).format(no_cents_if_whole: true)
  end

  def self.transfer(organisation, from: 1.week.ago, to: Date.today - 1)
    # unless from
    #   most_recent_stripe_charge = organisation.stripe_charges.order('created desc').first
    #   from = most_recent_stripe_charge ? most_recent_stripe_charge.created.to_date + 1 : Date.today - 2
    # end
    return if from >= to

    puts "transferring charges for #{organisation.slug} from #{from} to #{to}"

    Stripe.api_key = organisation.stripe_sk
    Stripe.api_version = '2020-08-27'
    charges = Stripe::Charge.list(created: { gte: Time.utc(from.year, from.month, from.day).to_i, lt: Time.utc(to.year, to.month, to.day).to_i })

    charges.auto_paging_each do |charge|
      c = {}
      %w[id amount application_fee application_fee_amount balance_transaction created currency customer description destination payment_intent].each do |f|
        c[f] = case f
               when 'created'
                 Time.at(charge[f]).utc.strftime('%Y-%m-%d %H:%M:%S +0000')
               else
                 charge[f]
               end
      end
      %w[de_event_id de_order_id de_account_id].each do |f|
        c[f.gsub('de_', '')] = charge['metadata'][f]
      end
      %w[de_donation_revenue de_ticket_revenue de_discounted_ticket_revenue de_percentage_discount de_percentage_discount_monthly_donor de_credit_applied de_fixed_discount_applied].each do |f|
        x = charge['metadata'][f]
        c[f] = x.gsub(',', '.') if x
      end
      # puts c['created']
      begin
        organisation.stripe_charges.create(c)
      rescue StandardError
        # puts "error creating charge #{c['id']}"
      end
    end
  end

  def balance_from_transactions
    @balance_from_transactions ||= begin
      m = stripe_transactions.sum(&:gross_money)
      m > 0 ? m.exchange_to(currency) : Money.new(0, currency)
    end
  end

  def fees_from_transactions
    @fees_from_transactions ||= begin
      m = stripe_transactions.sum(&:fee_money)
      m > 0 ? m.exchange_to(currency) : Money.new(0, currency)
    end
  end

  def balance
    Money.new balance_float * 100, currency
  end

  def fees
    Money.new fees_float * 100, currency
  end

  def de_donation_revenue_money
    Money.new de_donation_revenue * 100, currency
  end

  def de_discounted_ticket_revenue_money
    Money.new de_discounted_ticket_revenue * 100, currency
  end

  def de_credit_applied_money
    Money.new de_credit_applied * 100, currency
  end

  def de_fixed_discount_applied_money
    Money.new de_fixed_discount_applied * 100, currency
  end

  def amount_money
    Money.new amount, currency
  end

  def application_fee_amount_money
    Money.new application_fee_amount, currency
  end

  def ticket_revenue
    if application_fee_amount
      if application_fee_amount == 0 && balance == 0
        de_discounted_ticket_revenue_money
      elsif application_fee_amount > 0
        de_discounted_ticket_revenue_money * (balance / application_fee_amount_money)
      else
        Money.new(0, currency)
      end
    else
      balance - de_donation_revenue_money
    end
  end

  def ticket_revenue_to_organisation
    if application_fee_amount
      if application_fee_amount == 0 && balance == 0
        (application_fee_amount_money - de_donation_revenue_money)
      elsif application_fee_amount > 0
        (application_fee_amount_money - de_donation_revenue_money) * (balance / application_fee_amount_money)
      else
        Money.new(0, currency)
      end
    else
      ticket_revenue
    end
  end

  def ticket_revenue_to_revenue_sharer
    return Money.new(0, currency) unless application_fee_amount

    if application_fee_amount == 0 && balance == 0
      (amount_money - application_fee_amount_money)
    elsif application_fee_amount > 0
      (amount_money - application_fee_amount_money) * (balance / application_fee_amount_money)
    else
      Money.new(0, currency)
    end
  end

  def donations
    if application_fee_amount
      if application_fee_amount == 0 && balance == 0
        de_donation_revenue_money
      elsif application_fee_amount > 0
        de_donation_revenue_money * (balance / application_fee_amount_money)
      else
        Money.new(0, currency)
      end
    else
      [de_donation_revenue_money, balance].min
    end
  end
end
