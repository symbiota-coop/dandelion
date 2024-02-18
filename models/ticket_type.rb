class TicketType
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :event, index: true
  belongs_to :ticket_group, optional: true, index: true

  field :name, type: String
  field :description, type: String
  field :price, type: Float
  field :quantity, type: Integer
  field :order, type: Integer
  field :hidden, type: Boolean
  field :max_quantity_per_transaction, type: Integer
  field :minimum_monthly_donation, type: Float

  def self.admin_fields
    {
      name: :text,
      description: :text,
      price: :number,
      quantity: :number,
      order: :number,
      minimum_monthly_donation: :number,
      hidden: :check_box,
      max_quantity_per_transaction: :number,
      event_id: :lookup,
      tickets: :collection
    }
  end

  has_many :tickets, dependent: :nullify
  has_many :photos, as: :photoable, dependent: :destroy

  validates_presence_of :name, :price, :quantity

  before_validation do
    errors.add(:price, 'must not be not be < 0') if price && price < 0
    errors.add(:quantity, 'must not be not be < 0') if quantity && quantity < 0
    errors.add(:max_quantity_per_transaction, 'must not be not be < 0') if max_quantity_per_transaction && max_quantity_per_transaction < 0
  end

  def send_payment_reminder
    email = name.split.last
    return if EmailAddress.error(email)
    return if remaining <= 0

    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    ticket_type = self
    event = self.event
    content = ERB.new(File.read(Padrino.root('app/views/emails/payment_reminder.erb'))).result(binding)
    batch_message.from ENV['REMINDERS_EMAIL_FULL']
    batch_message.reply_to(event.email || event.organisation.reply_to)
    batch_message.subject "Payment reminder for #{event.name}"
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    batch_message.add_recipient(:to, email)

    batch_message.finalize if ENV['MAILGUN_API_KEY']
  end
  handle_asynchronously :send_payment_reminder

  def remaining
    (quantity || 0) - tickets.count
  end

  def wiser_remaining
    [remaining, ticket_group ? ticket_group.places_remaining : nil, event.places_remaining].compact.min
  end

  def number_of_tickets_available_in_single_purchase
    [remaining, ticket_group ? ticket_group.places_remaining : nil, event.places_remaining, max_quantity_per_transaction || nil].compact.min
  end
end
