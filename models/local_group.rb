class LocalGroup
  include Mongoid::Document
  include Mongoid::Timestamps
  extend Dragonfly::Model

  include ImportFromCsv
  include SendFollowersCsv

  belongs_to :organisation, index: true
  belongs_to :account, index: true

  field :name, type: String
  field :telegram_group, type: String
  field :intro_text, type: String
  field :geometry, type: String
  field :hide_members, type: Boolean
  field :type, type: String

  def self.admin_fields
    {
      name: :text,
      type: :text,
      telegram_group: :url,
      intro_text: :wysiwyg,
      geometry: :text_area,
      hide_members: :check_box
    }
  end

  validates_presence_of :name, :geometry

  has_many :discount_codes, class_name: 'DiscountCode', as: :codeable, dependent: :destroy

  has_many :events, dependent: :nullify
  has_many :local_groupships, dependent: :destroy
  has_many :pmails_as_mailable, class_name: 'Pmail', as: :mailable, dependent: :destroy
  has_many :pmails_as_exclusion, class_name: 'Pmail', inverse_of: :local_group, dependent: :nullify
  def pmails_including_events
    Pmail.and(:id.in => pmails_as_mailable.pluck(:id) + Pmail.and(:mailable_type => 'Event', :mailable_id.in => events.pluck(:id)).pluck(:id))
  end

  has_many :zoomships, dependent: :destroy

  embeds_many :polygons

  before_validation do
    polygons.destroy_all
    g = JSON.parse(geometry)
    unless g['coordinates']
      g = g['features'].first['geometry']
      self.geometry = g.to_json
    end
    g['coordinates'].each do |polygon|
      polygons.build coordinates: (g['type'] == 'Polygon' ? [polygon] : polygon)
    end

    # Ensure polygons were created and are valid
    errors.add(:geometry, 'is invalid - unable to create valid polygons') if geometry.present? && (polygons.empty? || polygons.any? { |p| !p.valid? })
  rescue StandardError => e
    errors.add(:geometry, e)
  end

  def event_tags
    EventTag.and(:id.in => EventTagship.and(:event_id.in => events.pluck(:id)).pluck(:event_tag_id))
  end

  def event_feedbacks
    EventFeedback.and(:event_id.in => events.pluck(:id))
  end

  def members
    Account.and(:id.in => local_groupships.pluck(:account_id))
  end

  def organisation_members_within
    organisation.members.and(coordinates: { '$geoWithin' => { '$geometry' => JSON.parse(geometry) } })
  end

  def self.human_attribute_name(attr, options = {})
    {
      telegram_group: 'Telegram group/channel URL'
    }[attr.to_sym] || super
  end

  def self.admin?(local_group, account)
    account && local_group &&
      (
        account.admin? ||
        local_group.local_groupships.find_by(account: account, admin: true) ||
        Organisation.admin?(local_group.organisation, account)
      )
  end

  def subscribed_members
    Account.and(:id.in => local_groupships.and(:unsubscribed.ne => true).pluck(:account_id))
  end

  def subscribed_accounts
    subscribed_members.and(:id.in => organisation.subscribed_accounts.pluck(:id))
  end

  def unsubscribed_members
    Account.and(:id.in => local_groupships.and(unsubscribed: true).pluck(:account_id))
  end

  def admins
    Account.and(:id.in => local_groupships.and(admin: true).pluck(:account_id))
  end

  def admins_receiving_feedback
    Account.and(:id.in => local_groupships.and(admin: true).and(receive_feedback: true).pluck(:account_id))
  end
end
