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
  field :range_min, type: Float
  field :range_max, type: Float
  field :max_quantity_per_transaction, type: Integer
  field :minimum_monthly_donation, type: Float
  field :sales_end, type: Time

  attr_writer :price_or_range
  attr_accessor :price_or_range_submitted

  def price_or_range
    @price_or_range || (
      if range_min && range_max
        "#{range_min.to_i == range_min ? range_min.to_i : range_min}-#{range_max.to_i == range_max ? range_max.to_i : range_max}"
      end
    ) || (price.to_i == price ? price.to_i : price)
  end

  def self.admin_fields
    {
      name: :text,
      description: :text,
      price: :number,
      range_min: :number,
      range_max: :number,
      quantity: :number,
      order: :number,
      minimum_monthly_donation: :number,
      hidden: :check_box,
      max_quantity_per_transaction: :number,
      sales_end: :datetime,
      event_id: :lookup,
      tickets: :collection
    }
  end

  has_many :tickets, dependent: :nullify
  has_many :photos, as: :photoable, dependent: :destroy

  validates_presence_of :name, :quantity

  before_validation do
    if @price_or_range_submitted
      self.price = nil
      self.range_min = nil
      self.range_max = nil
      if @price_or_range
        if @price_or_range.to_s.include?('-')
          r_min, r_max = @price_or_range.to_s.split('-')
          self.range_min = r_min if floaty?(r_min)
          self.range_max = r_max if floaty?(r_max)
        elsif floaty?(@price_or_range)
          self.price = @price_or_range
        end
      end
    end

    errors.add(:range_min, 'must not be < 0') if range_min && range_min < 0
    errors.add(:range_max, 'must not be < 0') if range_max && range_max < 0
    errors.add(:range_max, 'must be > range min') if range_min && range_max && range_max <= range_min
    errors.add(:price, 'must not be < 0') if price && price < 0
    errors.add(:quantity, 'must not be < 0') if quantity && quantity < 0
    errors.add(:max_quantity_per_transaction, 'must not be < 0') if max_quantity_per_transaction && max_quantity_per_transaction < 0
  end

  def range
    range_min && range_max ? [range_min, range_max] : nil
  end

  def floaty?(obj)
    !Float(obj).nil?
  rescue StandardError
    false
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
    (quantity || 0) - tickets.and(made_available_at: nil).count
  end

  def remaining_including_made_available
    (quantity || 0) - tickets.count
  end

  def wiser_remaining
    [remaining, ticket_group ? ticket_group.places_remaining : nil, event.places_remaining].compact.min
  end

  def number_of_tickets_available_in_single_purchase
    [remaining, ticket_group ? ticket_group.places_remaining : nil, event.places_remaining, max_quantity_per_transaction || nil].compact.min
  end
end
