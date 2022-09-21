class Order
  class OrderNotFound < StandardError; end

  class Restored < StandardError; end

  class PaymentMethodNotFound < StandardError; end

  class NoTickets < StandardError; end
  include Mongoid::Document
  include Mongoid::Timestamps
  include Mongoid::Paranoia

  belongs_to :event, index: true, optional: true
  belongs_to :account, class_name: 'Account', inverse_of: :orders, index: true, optional: true
  belongs_to :revenue_sharer, class_name: 'Account', inverse_of: :orders_as_revenue_sharer, index: true, optional: true
  belongs_to :affiliate, polymorphic: true, index: true, optional: true
  belongs_to :discount_code, index: true, optional: true

  field :value, type: Float
  field :original_description, type: String
  field :percentage_discount, type: Integer
  field :percentage_discount_monthly_donor, type: Integer
  field :session_id, type: String
  field :payment_intent, type: String
  field :transfer_id, type: String
  field :coinbase_checkout_id, type: String
  field :seeds_secret, type: String
  field :seeds_value, type: Float
  field :evm_secret, type: String
  field :evm_value, type: BigDecimal
  field :payment_completed, type: Boolean
  field :application_fee_amount, type: Float
  field :currency, type: String
  field :opt_in_organisation, type: Boolean
  field :opt_in_facilitator, type: Boolean
  field :credit_applied, type: Float
  field :organisation_revenue_share, type: Float
  field :hear_about, type: String
  field :http_referrer, type: String
  field :message_ids, type: String
  field :answers, type: Array

  def self.admin_fields
    {
      value: :number,
      currency: :text,
      credit_applied: :number,
      percentage_discount: :number,
      percentage_discount_monthly_donor: :number,
      application_fee_amount: :number,
      organisation_revenue_share: :number,
      http_referrer: :text,
      session_id: :text,
      payment_intent: :text,
      transfer_id: :text,
      coinbase_checkout_id: :text,
      seeds_secret: :text,
      seeds_value: :number,
      evm_secret: :text,
      evm_value: :number,
      payment_completed: :check_box,
      opt_in_organisation: :check_box,
      opt_in_facilitator: :check_box,
      message_ids: :text_area,
      answers: { type: :text_area, disabled: true },
      event_id: :lookup,
      account_id: :lookup,
      discount_code_id: :lookup,
      original_description: :text_area,
      tickets: :collection,
      donations: :collection
    }
  end

  after_save do
    event.clear_cache if event
  end
  after_destroy do
    event.clear_cache if event
  end

  validates_uniqueness_of :session_id, :payment_intent, :coinbase_checkout_id, allow_nil: true
  validates_uniqueness_of :seeds_secret, scope: :seeds_value, allow_nil: true
  validates_uniqueness_of :evm_secret, scope: :evm_value, allow_nil: true

  def self.currencies
    [''] + CURRENCIES_HASH
  end

  has_many :tickets, dependent: :destroy
  has_many :donations, dependent: :destroy

  has_many :notifications, as: :notifiable, dependent: :destroy

  def circle
    account
  end

  def self.email_viewer?(order, account)
    account && order && (Event.email_viewer?(order.event, account) || (order.opt_in_facilitator && Event.admin?(order.event, account)))
  end

  def restore_and_complete
    tickets.deleted.each { |ticket| ticket.restore }
    donations.deleted.each { |donation| donation.restore }
    restore
    set(payment_completed: true)
    update_destination_payment
    send_tickets
    create_order_notification
  end

  def self.incomplete
    self.and(:id.in =>
        Order.and(:payment_intent.ne => nil).and(:payment_completed.ne => true).pluck(:id) +
        Order.and(:coinbase_checkout_id.ne => nil).and(:payment_completed.ne => true).pluck(:id) +
        Order.and(:seeds_secret.ne => nil).and(:payment_completed.ne => true).pluck(:id) +
        Order.and(:evm_secret.ne => nil).and(:payment_completed.ne => true).pluck(:id))
  end

  def incomplete?
    (payment_intent && !payment_completed) || (coinbase_checkout_id && !payment_completed) || (seeds_secret && !payment_completed) || (evm_secret && !payment_completed)
  end

  def self.complete
    self.and(:id.in =>
        Order.and(value: nil).pluck(:id) +
        Order.and(payment_completed: true).pluck(:id))
  end

  def complete?
    value.nil? || payment_completed
  end

  def description_elements
    d = []
    TicketType.and(:id.in => tickets.pluck(:ticket_type_id)).each do |ticket_type|
      d << "#{ticket_type.name} ticket #{Money.new(ticket_type.price * 100, currency).format(no_cents_if_whole: true)}x#{tickets.and(ticket_type: ticket_type).count}"
    end

    d << "#{percentage_discount}% discount" if percentage_discount
    d << "#{percentage_discount_monthly_donor}% discount" if percentage_discount_monthly_donor

    donations.each do |donation|
      d << "#{Money.new(donation.amount * 100, currency).format(no_cents_if_whole: true)} donation"
    end

    d << "#{Money.new(credit_applied * 100, currency).format(no_cents_if_whole: true)} credit applied" if credit_applied

    d
  end

  def description
    d = description_elements
    "#{event.name}, #{event.when_details(account.try(:time_zone))}#{" at #{event.location}" if event.location != 'Online'}#{": #{d.join(', ')}" unless d.empty?}"
  end

  def evm_offset
    if CELO_CURRENCIES.include?(currency)
      evm_secret.to_d / 1e8
    else
      evm_secret.to_d / 1e15
    end
  end

  before_validation do
    self.evm_value = value.to_d + evm_offset if evm_secret && !evm_value
    if seeds_secret && !seeds_value
      self.seeds_value = value
      # agent = Mechanize.new
      # seeds = JSON.parse(agent.get('https://newdex.io/api/symbol/getSymbolInfo', { symbol: 'token.seeds-seeds-tlos' }).body)
      # telos = JSON.parse(agent.get('https://api.coingecko.com/api/v3/simple/price?ids=telos&vs_currencies=usd').body)
      # seeds_usd = seeds['symbolInfo']['askPrice'] * telos['telos']['usd']
      # self.seeds_value = (Money.new(value * 100, currency).exchange_to('USD').dollars.to_i / seeds_usd).round
    end
    self.discount_code = nil if discount_code && !discount_code.applies_to?(event)
    self.percentage_discount = discount_code.percentage_discount if discount_code
    if !event.no_discounts && (account && event && event.organisation && (organisationship = event.organisation.organisationships.find_by(account: account)) && (organisationship.monthly_donor? && organisationship.monthly_donor_discount > 0))
      self.percentage_discount_monthly_donor = organisationship.monthly_donor_discount
    end
    if cohost && !affiliate_type && !affiliate_id
      self.affiliate_type = 'Organisation'
      self.affiliate_id = Organisation.find_by(slug: cohost).try(:id)
    end
    if affiliate_type && %w[Account Organisation].include?(affiliate_type)
      unless affiliate_type.constantize.find(affiliate_id)
        self.affiliate_id = nil
        self.affiliate_type = nil
      end
    else
      self.affiliate_id = nil
      self.affiliate_type = nil
    end
  end

  def ticket_revenue
    r = Money.new(0, currency)
    tickets.each { |ticket| r += Money.new((ticket.price || 0) * 100, currency) }
    r
  end

  def discounted_ticket_revenue
    r = Money.new(0, currency)
    tickets.each { |ticket| r += Money.new((ticket.discounted_price || 0) * 100, currency) }
    r
  end

  def organisation_discounted_ticket_revenue
    r = Money.new(0, currency)
    tickets.each { |ticket| r += Money.new((ticket.discounted_price || 0) * 100 * (organisation_revenue_share || 1), currency) }
    r
  end

  def donation_revenue
    r = Money.new(0, currency)
    donations.each { |donation| r += Money.new((donation.amount || 0) * 100, currency) }
    r
  end

  def apply_credit
    if (organisationship = event.organisation.organisationships.find_by(account: account))
      begin
        credit_balance = organisationship.credit_balance.exchange_to(currency)
      rescue Money::Bank::UnknownRate
        return
      end
      if credit_balance > 0
        if credit_balance >= (discounted_ticket_revenue + donation_revenue)
          update_attribute(:credit_applied, (discounted_ticket_revenue + donation_revenue).cents.to_f / 100)
        elsif credit_balance < (discounted_ticket_revenue + donation_revenue)
          update_attribute(:credit_applied, credit_balance.cents.to_f / 100)
        end
      end
    end
  end

  after_create do
    if opt_in_organisation
      event.organisation_and_cohosts.each do |organisation|
        organisation.organisationships.create account: account
      end
      event.activity.activityships.create account: account if event.activity && event.activity.privacy == 'open'
      event.local_group.local_groupships.create account: account if event.local_group
    end
  end

  def update_destination_payment
    return unless application_fee_amount

    begin
      Stripe.api_key = event.organisation.stripe_sk
      Stripe.api_version = '2020-08-27'
      pi = Stripe::PaymentIntent.retrieve payment_intent
      transfer = Stripe::Transfer.retrieve pi.charges.first.transfer

      Stripe.api_key = JSON.parse(event.revenue_sharer_organisationship.stripe_connect_json)['access_token']
      Stripe.api_version = '2020-08-27'
      destination_payment = Stripe::Charge.retrieve transfer.destination_payment
      Stripe::Charge.update(destination_payment.id, {
                              description: "#{account.name}: #{description}",
                              metadata: metadata
                            })
    rescue StandardError => e
      Airbrake.notify(e)
    end
  end

  attr_accessor :prevent_refund, :cohost

  after_destroy :refund
  def refund
    if event.refund_deleted_orders && !prevent_refund && event.organisation && value && value > 0 && payment_completed && payment_intent
      begin
        Stripe.api_key = event.organisation.stripe_sk
        Stripe.api_version = '2020-08-27'
        pi = Stripe::PaymentIntent.retrieve payment_intent
        if event.revenue_sharer_organisationship
          Stripe::Refund.create(
            charge: pi.charges.first.id,
            refund_application_fee: true,
            reverse_transfer: true
          )
        else
          Stripe::Refund.create(charge: pi.charges.first.id)
        end
      rescue Stripe::InvalidRequestError
        true
      end
    end
  end

  def metadata
    order = self
    {
      de_event_id: event.id,
      de_order_id: order.id,
      de_account_id: order.account_id,
      de_donation_revenue: order.donation_revenue,
      de_ticket_revenue: order.ticket_revenue,
      de_discounted_ticket_revenue: order.discounted_ticket_revenue,
      de_percentage_discount: order.percentage_discount,
      de_percentage_discount_monthly_donor: order.percentage_discount_monthly_donor,
      de_credit_applied: order.credit_applied
    }
  end

  def total
    ((discounted_ticket_revenue + donation_revenue).cents.to_f / 100) - (credit_applied || 0)
  end

  def calculate_application_fee_amount
    (((discounted_ticket_revenue.cents * organisation_revenue_share) + donation_revenue.cents).to_f / 100) - (credit_payable_to_organisation || 0)
  end

  def credit_payable_to_organisation
    credit_applied - credit_payable_to_revenue_sharer if organisation_revenue_share && credit_applied && credit_applied > 0
  end

  def credit_payable_to_revenue_sharer
    ((discounted_ticket_revenue / (discounted_ticket_revenue + donation_revenue)) * credit_applied * (1 - organisation_revenue_share)).to_f if organisation_revenue_share && credit_applied && credit_applied > 0
  end

  def make_transfer
    if event.revenue_sharer_organisationship && credit_payable_to_revenue_sharer && credit_payable_to_revenue_sharer > 0

      Stripe.api_key = event.organisation.stripe_sk
      Stripe.api_version = '2020-08-27'
      transfer = Stripe::Transfer.create({
                                           amount: (credit_payable_to_revenue_sharer * 100).round,
                                           currency: currency,
                                           destination: event.revenue_sharer_organisationship.stripe_user_id,
                                           metadata: metadata
                                         })
      set(transfer_id: transfer.id)

    end
  end

  def tickets_pdf
    order = self
    unit = 2.83466666667 # units / mm
    cm = 10 * unit
    width = 21 * cm
    margin = 1 * cm
    qr_size = width / 1.5
    Prawn::Document.new(page_size: 'A4', margin: margin) do |pdf|
      order.tickets.each_with_index do |ticket, i|
        pdf.start_new_page unless i == 0
        pdf.font "#{Padrino.root}/app/assets/fonts/circular-ttf/CircularStd-Book.ttf"
        pdf.image (event.organisation.send_ticket_emails_from_organisation && event.organisation.image ? open(Addressable::URI.escape(event.organisation.image.url)) : "#{Padrino.root}/app/assets/images/black-on-white-sq.png"), width: width / 4, position: :center
        pdf.text order.event.name, align: :center, size: 32
        pdf.move_down 0.5 * cm
        pdf.text order.event.when_details(order.account.time_zone), align: :center, size: 14
        pdf.move_down 0.5 * cm
        pdf.indent((width / 2) - (qr_size / 2) - margin) do
          pdf.print_qr_code ticket.id.to_s, extent: qr_size
        end
        pdf.move_down 0.5 * cm
        pdf.text ticket.account.name, align: :center, size: 14
        pdf.move_down 0.5 * cm
        pdf.text ticket.ticket_type.name, align: :center, size: 14
        pdf.move_down 0.5 * cm
        pdf.text ticket.id.to_s, align: :center, size: 10
      end
    end
  end

  def send_tickets
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], 'api.eu.mailgun.net'
    batch_message = Mailgun::BatchMessage.new(mg_client, 'tickets.dandelion.earth')

    order = self
    event = order.event

    account = order.account
    content = ERB.new(File.read(Padrino.root('app/views/emails/tickets.erb'))).result(binding)
    batch_message.subject "#{tickets.count == 1 ? 'Ticket' : 'Tickets'} to #{event.name}"

    if event.organisation.send_ticket_emails_from_organisation && event.organisation.reply_to && event.organisation.image
      header_image_url = event.organisation.image.url
      batch_message.from event.organisation.reply_to
      batch_message.reply_to event.email
    else
      header_image_url = "#{ENV['BASE_URI']}/images/black-on-transparent-sq.png"
      batch_message.from 'Dandelion <tickets@dandelion.earth>'
      batch_message.reply_to(event.email || event.organisation.reply_to)
    end

    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    filename = "dandelion-#{event.name.parameterize}-#{order.id}.pdf"
    tickets_pdf_file = File.new(filename, 'w+')
    tickets_pdf_file.write order.tickets_pdf.render
    tickets_pdf_file.rewind
    batch_message.add_attachment tickets_pdf_file, filename

    [account].each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => (account.firstname || 'there'), 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    if ENV['MAILGUN_API_KEY']
      message_ids = batch_message.finalize
      update_attribute(:message_ids, message_ids)
    end

    tickets_pdf_file.close
    File.delete(filename)
  end
  handle_asynchronously :send_tickets

  def create_order_notification
    Notification.and(type: 'created_order').and(:notifiable_id.in => event.orders.and(account: account).pluck(:id)).destroy_all
    notifications.create! circle: circle, type: 'created_order' if account.public?
  end
end
