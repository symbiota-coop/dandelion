class Order
  include Mongoid::Document
  include Mongoid::Timestamps
  include BelongsToWithoutParentValidation

  include Mongoid::Paranoia
  %w[OrderNotFound Restored PaymentMethodNotFound NoTickets].each do |error_class|
    const_set(error_class, Class.new(StandardError))
  end

  include OrderFields
  include OrderNotifications
  include OrderAccounting

  belongs_to_without_parent_validation :event, index: true, optional: true
  belongs_to_without_parent_validation :account, class_name: 'Account', inverse_of: :orders, index: true, optional: true
  belongs_to_without_parent_validation :revenue_sharer, class_name: 'Account', inverse_of: :orders_as_revenue_sharer, index: true, optional: true
  belongs_to_without_parent_validation :affiliate, polymorphic: true, index: true, optional: true
  belongs_to_without_parent_validation :discount_code, optional: true # removed index

  has_many :stripe_charges

  has_many :tickets, dependent: :destroy
  has_many :donations, dependent: :destroy

  has_many :notifications, as: :notifiable, dependent: :destroy

  validates_uniqueness_of :session_id, :payment_intent, :coinbase_checkout_id, allow_nil: true
  validates_uniqueness_of :evm_secret, scope: :evm_value, allow_nil: true

  before_validation do
    self.evm_value = value.to_d + evm_offset if evm_secret && !evm_value
    self.discount_code = nil if discount_code && !discount_code.applies_to?(event)
    self.percentage_discount = discount_code.percentage_discount if discount_code && discount_code.percentage_discount
    if !percentage_discount && !event.no_discounts && (organisationship_for_discount = event.organisationship_for_discount(account))
      self.percentage_discount_monthly_donor = organisationship_for_discount.monthly_donor_discount
    end
    if cohost && !affiliate_type && !affiliate_id
      self.affiliate_type = 'Organisation'
      self.affiliate_id = Organisation.find_by(slug: cohost).try(:id)
    end
    if affiliate_type && %w[Account Organisation].include?(affiliate_type) && affiliate_id
      unless affiliate_type.constantize.find(affiliate_id)
        self.affiliate_id = nil
        self.affiliate_type = nil
      end
    else
      self.affiliate_id = nil
      self.affiliate_type = nil
    end
    self.application_fee_amount = application_fee_amount.ceil(2) if application_fee_amount && application_fee_amount.to_s.split('.').last.length >= 3
  end

  after_create do
    if opt_in_organisation
      event.organisation_and_cohosts.each do |organisation|
        organisation.organisationships.create account: account
      end
      event.activity.activityships.create account: account if event.activity && event.activity.privacy == 'open'
      event.local_group.local_groupships.create account: account if event.local_group
    end
    sign_up_to_gocardless if gc_plan_id
  end

  after_save do
    event.clear_cache if event
  end
  after_destroy do
    event.clear_cache if event
  end

  def self.currencies
    CURRENCY_OPTIONS
  end

  def self.incomplete
    self.and(:payment_completed.ne => true)
  end

  def self.complete
    self.and(payment_completed: true)
  end

  def self.discounted
    self.and(:id.in => self.and(:percentage_discount.ne => nil).pluck(:id) + self.and(:percentage_discount_monthly_donor.ne => nil).pluck(:id))
  end

  def self.email_viewer?(order, account)
    account && order && (Event.email_viewer?(order.event, account) || (order.opt_in_facilitator && Event.admin?(order.event, account)))
  end

  def circle
    account
  end

  def incomplete?
    !payment_completed
  end

  def complete?
    payment_completed
  end

  def evm_offset
    evm_secret.to_d / 1e6
  end

  def stripe_payment_status
    Stripe.api_key = event.organisation.stripe_connect_json ? ENV['STRIPE_SK'] : event.organisation.stripe_sk
    Stripe.api_version = '2020-08-27'
    session = Stripe::Checkout::Session.retrieve(session_id)
    session.payment_status
  end

  def coinbase_payment_status
    event.organisation.coinbase_confirmed_checkout_ids.include?(coinbase_checkout_id)
  end

  def payment_completed!
    set(payment_completed: true)
    tickets.set(payment_completed: true)
    donations.set(payment_completed: true)
    tickets.each(&:payment_completed!)
    event.clear_cache if event
  end

  def restore_and_complete
    tickets.deleted.each(&:restore)
    donations.deleted.each(&:restore)
    restore
    set(restored: true)
    payment_completed!
    update_destination_payment
    send_tickets
    create_order_notification
  end

  def description_elements
    d = []
    TicketType.and(:id.in => tickets.pluck(:ticket_type_id)).each do |ticket_type|
      d << "#{"#{ticket_type.name} " if ticket_type}#{Money.new(ticket_type.price * 100, currency).format(no_cents_if_whole: true) if ticket_type.price}x#{tickets.and(ticket_type: ticket_type).count}"
    end

    d << "#{percentage_discount}% discount" if percentage_discount
    d << "#{percentage_discount_monthly_donor}% discount" if percentage_discount_monthly_donor

    donations.each do |donation|
      d << "#{Money.new(donation.amount * 100, currency).format(no_cents_if_whole: true)} donation #{'to Dandelion' if application_fee_paid_to_dandelion}"
    end

    d << "#{Money.new(credit_applied * 100, currency).format(no_cents_if_whole: true)} credit applied" if credit_applied

    d << "#{Money.new(fixed_discount_applied * 100, currency).format(no_cents_if_whole: true)} discount" if fixed_discount_applied

    d
  end

  def description
    d = description_elements
    text = event.organisation.use_event_slugs_in_order_descriptions ? "#{event.slug}, " : "#{event.name}, "
    text + "#{event.when_details(account.try(:time_zone))}#{" at #{event.location}" if event.location != 'Online'}#{": #{d.join(', ')}" unless d.empty?}"
  end

  def filter_discounts
    # return == leave existing discounts
    return unless discount_code&.filter

    filters = discount_code.filter.downcase.split(',').map(&:strip)
    return if tickets.all? do |ticket|
      filters.any? { |filter| ticket.ticket_type.name.downcase.include?(filter) }
    end

    # otherwise, remove discounts
    self.discount_code = nil
    self.percentage_discount = nil
    save
    tickets.each do |ticket|
      ticket.percentage_discount = nil
      ticket.save
    end
  end

  def apply_credit
    return unless (organisationship = event.organisation.organisationships.find_by(account: account))

    begin
      credit_balance = organisationship.credit_balance.exchange_to(currency)
    rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
      return
    end
    return unless credit_balance.positive?

    current_total = discounted_ticket_revenue + donation_revenue
    if credit_balance >= current_total
      update_attribute(:credit_applied, current_total.cents.to_f / 100)
    elsif credit_balance < current_total
      update_attribute(:credit_applied, credit_balance.cents.to_f / 100)
    end
  end

  def apply_fixed_discount
    return unless discount_code && discount_code.fixed_discount

    fixed_discount = discount_code.fixed_discount.exchange_to(currency)
    current_total = discounted_ticket_revenue + donation_revenue - Money.new((credit_applied || 0) * 100, currency)
    if fixed_discount >= current_total
      update_attribute(:fixed_discount_applied, current_total.cents.to_f / 100)
    elsif fixed_discount < current_total
      update_attribute(:fixed_discount_applied, fixed_discount.cents.to_f / 100)
    end
  end

  def update_destination_payment
    return unless application_fee_amount
    return if application_fee_paid_to_dandelion?

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
    rescue Stripe::InvalidRequestError => e
      Honeybadger.notify(e) unless e.message.include?('No such charge') || e.message.include?('No such transfer')
    rescue StandardError => e
      Honeybadger.notify(e)
    end
  end

  after_destroy :refund
  def refund
    return unless event.refund_deleted_orders && !prevent_refund && event.organisation && value && value.positive? && payment_completed && payment_intent

    # begin
    Stripe.api_key = event.organisation.stripe_connect_json ? ENV['STRIPE_SK'] : event.organisation.stripe_sk
    Stripe.api_version = '2020-08-27'
    pi = Stripe::PaymentIntent.retrieve payment_intent, { stripe_account: event.organisation.stripe_user_id }.compact
    if event.revenue_sharer_organisationship
      Stripe::Refund.create(
        charge: pi.charges.first.id,
        refund_application_fee: true,
        reverse_transfer: true
      )
    elsif event.organisation.stripe_user_id
      if application_fee_amount && application_fee_amount > 0
        Stripe::Refund.create({
                                charge: pi.charges.first.id,
                                refund_application_fee: true
                              },
                              { stripe_account: event.organisation.stripe_user_id })
      else
        Stripe::Refund.create({
                                charge: pi.charges.first.id
                              },
                              { stripe_account: event.organisation.stripe_user_id })
      end
    else
      Stripe::Refund.create({ charge: pi.charges.first.id })
    end
  rescue Stripe::InvalidRequestError => e
    notify_of_failed_refund(e)
    true
  end

  def tickets_pdf
    order = self
    unit = 2.83466666667 # units / mm
    cm = 10 * unit
    width = 21 * cm
    margin = 1 * cm
    qr_size = width / 2.5
    Prawn::Document.new(page_size: 'A4', margin: margin) do |pdf|
      order.tickets.each_with_index do |ticket, i|
        pdf.start_new_page unless i.zero?
        pdf.font "#{Padrino.root}/app/assets/fonts/PlusJakartaSans/ttf/PlusJakartaSans-Regular.ttf"
        pdf.image (event.organisation.send_ticket_emails_from_organisation && event.organisation.image ? URI.parse(Addressable::URI.escape(event.organisation.image.thumb('1920x1920').url)).open : "#{Padrino.root}/app/assets/images/black-on-transparent-trim.png"), width: width / 4, position: :center
        pdf.move_down 0.5 * cm
        pdf.text order.event.name, align: :center, size: 32
        pdf.move_down 0.5 * cm
        pdf.text order.event.when_details(order.account.time_zone), align: :center, size: 14
        pdf.move_down 0.5 * cm
        pdf.indent((width / 2) - (qr_size / 2) - margin) do
          pdf.print_qr_code ticket.id.to_s, extent: qr_size
        end
        pdf.move_down 0.5 * cm
        pdf.text ticket.account.name, align: :center, size: 14
        if ticket.ticket_type
          pdf.move_down 0.5 * cm
          pdf.text "#{ticket.ticket_type.name}, #{Money.new((ticket.discounted_price || 0) * 100, ticket.currency).format(no_cents_if_whole: true)}", align: :center, size: 14
        end
        pdf.move_down 0.5 * cm
        pdf.text ticket.id.to_s, align: :center, size: 10
      end
    end
  end

  def create_order_notification
    send_notification if event.send_order_notifications
    Notification.and(type: 'created_order').and(:notifiable_id.in => event.orders.and(account: account).pluck(:id)).destroy_all
    return unless account.public? && event.live? && event.public?

    notifications.create! circle: circle, type: 'created_order'
  end

  def sign_up_to_gocardless
    return unless [gc_plan_id, gc_given_name, gc_family_name, gc_address_line1, gc_city, gc_postal_code, gc_branch_code, gc_account_number].all?(&:present?)

    f = Ferrum::Browser.new
    f.go_to("https://pay.gocardless.com/#{gc_plan_id}")
    sleep 5
    f.at_css('#given_name').focus.type(gc_given_name)
    f.at_css('#family_name').focus.type(gc_family_name)
    f.at_css('#email').focus.type(account.email)
    # f.screenshot(path: 'screenshot1.png')
    f.css('form button[type=button]').last.scroll_into_view.click
    sleep 5
    f.at_css('#address_line1').focus.type(gc_address_line1)
    f.at_css('#city').focus.type(gc_city)
    f.at_css('#postal_code').focus.type(gc_postal_code)
    # f.screenshot(path: 'screenshot2.png')
    f.at_css('form button[type=submit]').scroll_into_view.click
    sleep 5
    f.at_css('#branch_code').focus.type(gc_branch_code)
    f.at_css('#account_number').focus.type(gc_account_number)
    # f.screenshot(path: 'screenshot3.png')
    f.at_css('form button[type=submit]').scroll_into_view.click
    sleep 5
    # f.screenshot(path: 'screenshot4.png')
    f.at_css('button[type=submit]').scroll_into_view.click
    # sleep 5
    # f.screenshot(path: 'screenshot5.png')
    %i[gc_plan_id gc_given_name gc_family_name gc_address_line1 gc_city gc_postal_code gc_branch_code gc_account_number].each { |f| set(f => nil) }
    set(gc_success: true)
  end
  handle_asynchronously :sign_up_to_gocardless
end
