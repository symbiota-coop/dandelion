class Place
  include Mongoid::Document
  include Mongoid::Timestamps
  include Geocoder::Model::Mongoid
  extend Dragonfly::Model

  belongs_to :account, index: true, optional: true

  field :name, type: String
  field :name_transliterated, type: String
  field :location, type: String
  field :website, type: String
  field :coordinates, type: Array
  field :image_uid, type: String

  def self.admin_fields
    {
      name: :text,
      name_transliterated: { type: :text, disabled: true },
      website: :url
    }
  end

  validates_presence_of :name, :location

  before_validation do
    self.name_transliterated = I18n.transliterate(name) if name
  end

  has_many :posts, as: :commentable, dependent: :destroy
  has_many :subscriptions, as: :commentable, dependent: :destroy
  has_many :comments, as: :commentable, dependent: :destroy
  has_many :comment_reactions, as: :commentable, dependent: :destroy

  has_many :notifications_as_notifiable, as: :notifiable, dependent: :destroy, class_name: 'Notification', inverse_of: :notifiable
  has_many :notifications_as_circle, as: :circle, dependent: :destroy, class_name: 'Notification', inverse_of: :circle
  after_create do
    notifications_as_notifiable.create! circle: account, type: 'created_place'
  end

  has_many :placeships, dependent: :destroy

  def discussers
    Account.and(:id.in => placeships.and(:unsubscribed.ne => true).pluck(:account_id))
  end

  def followers
    Account.and(:id.in => placeships.pluck(:account_id))
  end

  dragonfly_accessor :image
  before_validation do
    if image
      begin
        if %w[jpeg png gif pam].include?(image.format)
          image.name = "#{SecureRandom.uuid}.#{image.format}"
        else
          errors.add(:image, 'must be an image')
        end
      rescue StandardError
        self.image = nil
        errors.add(:image, 'must be an image')
      end
    end
  end

  # Geocoder
  geocoded_by :location
  def lat
    coordinates[1] if coordinates
  end

  def lng
    coordinates[0] if coordinates
  end
  after_validation do
    if location_changed?
      if location
        geocode || (self.coordinates = nil)
      else
        self.coordinates = nil
      end
    end
  end

  def self.marker_color
    '#FF5241'
  end

  def self.marker_icon
    'map-icon map-icon-natural-feature'
  end
end
