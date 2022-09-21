class Service
  include Mongoid::Document
  include Mongoid::Timestamps
  extend Dragonfly::Model

  belongs_to :account
  belongs_to :organisation

  field :name, type: String
  field :duration_in_minutes, type: Integer
  field :price, type: Float
  field :currency, type: String
  field :organisation_revenue_share, type: Float
  field :extra_info_for_booking_email, type: String
  field :description, type: String
  Date::DAYNAMES.each do |dayname|
    field :"available_#{dayname.downcase}", type: Boolean
  end
  field :start_hour, type: Integer
  field :end_hour, type: Integer

  %w[refund_deleted_orders draft secret].each do |b|
    field b.to_sym, type: Boolean
    index({ b.to_s => 1 })
  end

  def self.admin_fields
    {
      name: :text,
      duration_in_minutes: :number,
      price: :number,
      currency: :text,
      organisation_revenue_share: :number,
      organisation_id: :lookup,
      account_id: :lookup
    }.merge(Date::DAYNAMES.map { |dayname| [:"available_#{dayname.downcase}", :check_box] }.to_h)
  end

  def self.currencies
    [''] + CURRENCIES_HASH
  end

  has_many :bookings, dependent: :destroy

  validates_presence_of :name, :duration_in_minutes, :price, :currency, :start_hour, :end_hour, :organisation_revenue_share

  before_validation do
    errors.add(:account, 'is not connected to this organisation') if account && !organisationship
    errors.add(:start_hour, 'must be be between 0-23') if start_hour < 0 || start_hour > 23
    errors.add(:end_hour, 'must be be between 0-23') if end_hour < 0 || end_hour > 23
  end

  def available?(start_time, end_time, booking_id: nil)
    account.services.all? do |service|
      service.bookings.and(:start_time.lt => end_time).all? do |booking|
        !booking.persisted? || (booking_id && booking_id == booking.id) || start_time >= booking.end_time
      end
    end &&
      (account.calendar_events ? account.calendar_events.select { |event| event.dtstart < end_time }.all? { |event| start_time >= event.dtend } : true)
  end

  def name_with_provider
    "#{name} with #{account.name}"
  end

  def revenue
    r = Money.new(0, currency)
    bookings.each { |booking| r += booking.revenue }
    r
  end

  def self.draft
    self.and(draft: true)
  end

  def self.live
    self.and(:draft.ne => true)
  end

  def self.secret
    self.and(secret: true)
  end

  def self.public
    self.and(:secret.ne => true)
  end

  def live?
    !draft?
  end

  def public?
    !secret?
  end

  def self.admin?(service, account)
    account &&
      service &&
      (
      account.admin? ||
        service.account_id == account.id ||
        (service.organisation && Organisation.admin?(service.organisation, account))
    )
  end

  def organisationship
    organisation.organisationships.find_by(:account => account, :stripe_connect_json.ne => nil)
  end

  def self.human_attribute_name(attr, options = {})
    {
      refund_deleted_orders: 'Attempt to refund deleted bookings on Stripe'
    }.merge(Date::DAYNAMES.map { |dayname| [:"available_#{dayname.downcase}", dayname] }.to_h)[attr.to_sym] || super
  end
end
