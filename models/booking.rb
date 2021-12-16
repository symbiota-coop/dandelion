class Booking
  class BookingNotFound < StandardError; end

  class Restored < StandardError; end

  class PaymentMethodNotFound < StandardError; end
  include Mongoid::Document
  include Mongoid::Timestamps
  include Mongoid::Paranoia

  belongs_to :service
  belongs_to :account, inverse_of: :bookings
  belongs_to :service_provider, class_name: 'Account', inverse_of: :bookings_as_service_provider

  field :start_time, type: Time
  field :end_time, type: Time
  field :value, type: Float
  field :session_id, type: String
  field :payment_intent, type: String
  field :payment_completed, type: Boolean
  field :application_fee_amount, type: Float
  field :currency, type: String
  field :opt_in_organisation, type: Boolean
  field :opt_in_facilitator, type: Boolean
  field :client_note, type: String

  def self.admin_fields
    {
      start_time: :datetime,
      end_time: :datetime,
      service_id: :lookup,
      account_id: :lookup,
      service_provider_id: :lookup,
      value: :number,
      application_fee_amount: :number,
      currency: :text,
      opt_in_organisation: :check_box,
      opt_in_facilitator: :check_box
    }
  end

  def self.currencies
    [''] + CURRENCIES
  end

  before_validation do
    self.service_provider = service.account unless service_provider
    errors.add(:end_time, 'must be after start time') if end_time && start_time && end_time <= start_time
    unless service.available?(start_time, end_time, booking_id: id)
      errors.add(:start_time, 'is unavailable')
      errors.add(:end_time, 'is unavailable')
    end
  end

  def self.incomplete
    self.and(:id.in => Order.and(:payment_intent.ne => nil).and(:payment_completed.ne => true).pluck(:id))
  end

  def incomplete?
    (payment_intent && !payment_completed)
  end

  def revenue
    r = Money.new(0, currency)
    r += Money.new((value || 0) * 100, currency)
    r
  end

  def description
    d = []

    d << Money.new((value || 0) * 100, currency).format(no_cents_if_whole: true).to_s

    "#{service.name_with_provider}, #{when_details(account.time_zone)}#{": #{d.join(', ')}" unless d.empty?}"
  end

  def metadata
    booking = self
    {
      de_service_id: service.id,
      de_booking_id: booking.id,
      de_account_id: booking.account_id
    }
  end

  def when_details(zone)
    zone ||= 'London'
    zone = zone.name unless zone.is_a?(String)
    start_time = self.start_time.in_time_zone(zone)
    end_time = self.end_time.in_time_zone(zone)
    z = "#{zone.include?('London') ? 'UK time' : zone} (UTC #{start_time.formatted_offset})"
    if start_time.to_date == end_time.to_date
      "#{start_time.to_date}, #{start_time.to_s(:no_double_zeros)} – #{end_time.to_s(:no_double_zeros)} #{z}"
    else
      "#{start_time.to_date}, #{start_time.to_s(:no_double_zeros)} – #{end_time.to_date}, #{end_time.to_s(:no_double_zeros)} #{z}"
    end
  end

  attr_accessor :prevent_refund

  after_destroy :refund
  def refund
    if service.refund_deleted_orders && !prevent_refund && service.organisation && value && value > 0 && payment_completed && payment_intent
      begin
        Stripe.api_key = service.organisation.stripe_sk
        pi = Stripe::PaymentIntent.retrieve payment_intent
        if service.organisationship
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

  def restore_and_complete
    restore
    set(payment_completed: true)
    send_confirmation_email
  end

  def send_confirmation_email
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], 'api.eu.mailgun.net'
    batch_message = Mailgun::BatchMessage.new(mg_client, 'tickets.dandelion.earth')

    booking = self
    service = booking.service
    account = booking.account

    #  client
    add_to_calendar = ERB.new(File.read(Padrino.root('app/views/services/_add_to_calendar.erb'))).result(binding)
    content = ERB.new(File.read(Padrino.root('app/views/emails/booking.erb'))).result(binding)
    batch_message.from 'Dandelion <bookings@dandelion.earth>'
    batch_message.reply_to service.organisation.reply_to if service.organisation.reply_to
    batch_message.subject "#{service.name_with_provider} confirmation"
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    [account].each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => (account.firstname || 'there'), 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']

    # provider
    add_to_calendar = ERB.new(File.read(Padrino.root('app/views/services/_add_to_calendar_provider.erb'))).result(binding)
    content = ERB.new(File.read(Padrino.root('app/views/emails/booking_for_provider.erb'))).result(binding)
    batch_message.from 'Dandelion <bookings@dandelion.earth>'
    batch_message.reply_to service.organisation.reply_to if service.organisation.reply_to
    batch_message.subject "#{service.name} booking: #{booking.account.name}"
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    [service.account].each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => (account.firstname || 'there'), 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
  end
end
