# A session someone offers to one person or a small group, by arrangement rather than at a set time: bodywork,
# meditation, coaching and so on. Each says how to book it (an email address, phone number or booking link)
class PrivateSession
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions
  include SlugLookup
  include Geocoded
  include Taggable

  extend Dragonfly::Model
  include ImageWithValidation

  def self.prewarmed_image_derivative_sizes
    %w[400x400# 800x800#]
  end

  belongs_to_without_parent_validation :account

  has_many :private_session_tagships, dependent: :destroy
  has_many :private_session_vouches, dependent: :destroy
  taggable tagships: :private_session_tagships, tag: :private_session_tag

  field :title, type: String
  field :slug, type: String
  field :description, type: String
  field :how_to_book, type: String
  field :delivery, type: String
  field :location, type: String
  field :coordinates, type: Array
  # Minutes: duration_min alone for one length, or both for a range
  field :duration_min, type: Integer
  field :duration_max, type: Integer
  field :max_participants, type: Integer
  # price for one price, or price_min and price_max for a sliding scale; none of them is by donation
  field :price, type: Float
  field :price_min, type: Float
  field :price_max, type: Float
  field :currency, type: String
  field :image_uid, type: String
  field :has_image, type: Boolean
  field :secret, type: Boolean
  # How many people have vouched for it, kept by PrivateSessionVouch, so lists needn't count each session's
  field :vouches_count, type: Integer, default: 0

  DELIVERIES = { 'In person' => 'in_person', 'Online' => 'online', 'In person or online' => 'either' }.freeze
  # A number, or a range of two (60, or 60-90), as the form takes length in minutes and price
  NUMBER_OR_RANGE = /\A(\d+(?:\.\d+)?)(?:-(\d+(?:\.\d+)?))?\z/

  validates_presence_of :title, :slug, :delivery, :how_to_book
  validates_uniqueness_of :slug
  validates_format_of :slug, with: /\A[a-z0-9-]+\z/
  validates_inclusion_of :delivery, in: DELIVERIES.values
  validates_numericality_of :max_participants, only_integer: true, greater_than_or_equal_to: 1
  validates_presence_of :location, if: :in_person?
  validates_inclusion_of :currency, in: FIAT_CURRENCIES

  before_validation do
    self.max_participants ||= 1
    self.currency ||= default_currency
    self.location = nil if delivery == 'online'
    assign_duration_or_range if @duration_or_range_given
    assign_price_or_range if @price_or_range_given
    errors.add(:duration_or_range, 'must be more than 0 minutes') if (duration_min && duration_min < 1) || (duration_max && duration_max < 1)
    errors.add(:price_or_range, 'must not be below 0') if [price, price_min, price_max].compact.any?(&:negative?)
    errors.add(:duration_or_range, 'must go from the lower to the higher number') if duration_min && duration_max && duration_max <= duration_min
    errors.add(:price_or_range, 'must go from the lower to the higher number') if price_min && price_max && price_max <= price_min
  end

  after_validation do
    if location_changed?
      if location.present?
        geocode || (self.coordinates = nil)
      else
        self.coordinates = nil
      end
    end
  end

  def self.protected_attributes
    %w[coordinates has_image tag_names_cache vouches_count]
  end

  # Length and price as the form takes them, a number or a range (TicketType's price_or_range does the same): stored
  # as numbers, so they can be sorted and compared
  def self.virtual_attributes
    super + %w[duration_or_range price_or_range]
  end

  def duration_or_range=(value)
    @duration_or_range = value
    @duration_or_range_given = true
  end

  def price_or_range=(value)
    @price_or_range = value
    @price_or_range_given = true
  end

  def duration_or_range
    return @duration_or_range if @duration_or_range_given

    number_or_range_text(duration_min, duration_max)
  end

  def price_or_range
    return @price_or_range if @price_or_range_given

    price ? number_text(price) : number_or_range_text(price_min, price_max)
  end

  # The tags shown on the session, from the cache Taggable keeps
  def tags
    tag_names_cache || []
  end

  def self.deliveries
    { '' => '' }.merge(DELIVERIES)
  end

  def self.listed
    self.and(secret: false)
  end

  def self.human_attribute_name(attr, options = {})
    {
      title: 'Name of the session',
      slug: 'URL',
      delivery: 'In person or online',
      duration_or_range: 'Length (minutes)',
      price_or_range: 'Price',
      max_participants: 'Maximum number of people',
      secret: 'Secret'
    }[attr.to_sym] || super
  end

  def self.new_hints
    {
      slug: 'Lowercase letters, numbers and dashes only (no spaces)',
      how_to_book: 'Your email address, phone number or booking link, and anything people should know when booking',
      description: 'What happens in a session, who it suits and anything people should know beforehand',
      location: 'Where you offer it: a town or area is enough',
      max_participants: "1 for one-to-one sessions, or the most you'll see at once",
      duration_or_range: 'A number of minutes, like 60, or a range, like 60-90',
      price_or_range: 'A price, like 60, or a sliding scale, like 40-80. Leave it blank for by donation.',
      image: 'Square images work best: images of other sizes will be cropped to a square',
      secret: 'Leave it off the list of private sessions and your profile: only people with the link see it'
    }
  end

  def self.edit_hints
    new_hints
  end

  def path
    "/ps/#{slug}"
  end

  def in_person?
    delivery.in?(%w[in_person either])
  end

  def online?
    delivery.in?(%w[online either])
  end

  def one_to_one?
    max_participants == 1
  end

  # Paid to the person offering it, so not in tokens
  def self.currencies
    FIAT_CURRENCIES
  end

  # The offering account's own currency, if it has chosen one
  def default_currency
    (account.default_currency if account && account.default_currency.present?) || 'GBP'
  end

  def refresh_vouches_count
    set(vouches_count: private_session_vouches.count)
  end

  def by_donation?
    !price && !price_min
  end

  def duration_label
    "#{number_or_range_text(duration_min, duration_max, '–')} min" if duration_min
  end

  def price_label(symbol)
    if by_donation?
      'By donation'
    elsif price
      "#{symbol}#{number_text(price)}"
    else
      "#{symbol}#{number_text(price_min)}–#{symbol}#{number_text(price_max)}"
    end
  end

  def group_size_label
    one_to_one? ? '1-1' : "Up to #{max_participants} people"
  end

  private

  # 60 for 60.0, 12.50 for 12.5
  def number_text(number)
    number == number.to_i ? number.to_i.to_s : format('%.2f', number)
  end

  def number_or_range_text(low, high, dash = '-')
    return unless low

    [low, high].compact.map { |n| number_text(n) }.join(dash)
  end

  # The number or range typed, as its low and high ends ([60, 60] for 60), or nil if it isn't one. Spaces and en
  # dashes as people type them: '60 – 90' is 60-90
  def number_or_range_bounds(text)
    match = NUMBER_OR_RANGE.match(text.to_s.gsub(/\s+/, '').tr('–—', '--'))
    [match[1], match[2] || match[1]].map { |n| BigDecimal(n) } if match
  end

  def assign_duration_or_range
    self.duration_min = self.duration_max = nil
    return if @duration_or_range.blank?

    low, high = number_or_range_bounds(@duration_or_range)
    if !low || low != low.to_i || high != high.to_i
      errors.add(:duration_or_range, 'must be a number of minutes, like 60, or a range, like 60-90')
    else
      self.duration_min = low.to_i
      self.duration_max = high.to_i if high != low
    end
  end

  def assign_price_or_range
    self.price = self.price_min = self.price_max = nil
    return if @price_or_range.blank?

    low, high = number_or_range_bounds(@price_or_range)
    if !low
      errors.add(:price_or_range, 'must be a number, like 60, or a range, like 40-80')
    elsif high == low
      self.price = low.to_f
    else
      self.price_min = low.to_f
      self.price_max = high.to_f
    end
  end
end
