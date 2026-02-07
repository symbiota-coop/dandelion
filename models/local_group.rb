class LocalGroup
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  extend Dragonfly::Model
  include ImportFromCsv
  include SendFollowersCsv
  include Searchable

  belongs_to_without_parent_validation :organisation
  belongs_to_without_parent_validation :account

  field :name, type: String
  field :intro_text, type: String
  field :geometry, type: String
  field :hide_members, type: Boolean
  field :type, type: String
  field :slug, type: String

  def self.search_fields
    %w[name]
  end

  def self.admin_fields
    {
      name: :text,
      type: :text,
      intro_text: :wysiwyg,
      geometry: :text_area,
      hide_members: :check_box
    }
  end

  validates_presence_of :name, :geometry, :slug
  validates_uniqueness_of :slug, scope: :organisation_id
  validates_format_of :slug, with: /\A[a-z0-9-]+\z/

  has_many :discount_codes, class_name: 'DiscountCode', as: :codeable, dependent: :destroy

  has_many :events, dependent: :nullify
  has_many :local_groupships, dependent: :destroy
  has_many :pmails_as_mailable, class_name: 'Pmail', as: :mailable, dependent: :destroy
  has_many :pmails_as_exclusion, class_name: 'Pmail', inverse_of: :local_group, dependent: :nullify
  def pmails_including_events
    Pmail.and(:id.in => pmails_as_mailable.pluck(:id) + Pmail.and(:mailable_type => 'Event', :mailable_id.in => events.pluck(:id)).pluck(:id))
  end

  has_many :zoomships, dependent: :destroy

  with_options class_name: 'Account', through: :local_groupships do
    has_many_through :members
    has_many_through :subscribed_members, conditions: { unsubscribed: false }
    has_many_through :unsubscribed_members, conditions: { unsubscribed: true }
    has_many_through :admins, conditions: { admin: true }
    has_many_through :admins_receiving_feedback, conditions: { admin: true, receive_feedback: true }
  end

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

  def organisation_members_within
    organisation.members.and(coordinates: { '$geoWithin' => { '$geometry' => JSON.parse(geometry) } })
  end

  def self.human_attribute_name(attr, options = {})
    {
      slug: 'URL',
      hide_members: 'Hide member map'
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

  def self.new_hints
    {
      geometry: 'Accepts a GeoJSON polygon created via https://geojson.io/ (copy and paste the contents of the box on the right)'
    }
  end

  def self.edit_hints
    {}.merge(new_hints)
  end

  def subscribed_accounts
    # Members subscribed to local_group AND subscribed to org AND not globally unsubscribed
    subscribed_members.and(subscribed_organisation_ids_cache: organisation_id, unsubscribed: false)
  end
end
