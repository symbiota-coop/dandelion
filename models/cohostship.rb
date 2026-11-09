class Cohostship
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  extend Dragonfly::Model
  include ImageWithValidation

  belongs_to_without_parent_validation :event
  belongs_to_without_parent_validation :organisation

  def self.prewarmed_image_derivative_sizes
    %w[32x32 992x992]
  end

  def self.prewarm_opengraph_image_derivative?
    true
  end

  field :image_uid, type: String
  field :image_width_unmagic, type: Integer
  field :image_height_unmagic, type: Integer
  field :has_image, type: Boolean
  field :featured, type: Boolean

  def self.protected_attributes
    %w[has_image]
  end

  before_validation do
    # New ones only, so any such co-hostship already saved can still be edited or removed
    errors.add(:organisation, 'is already the host') if new_record? && event && organisation_id == event.organisation_id
    if image
      begin
        if measure_image?
          self.image_width_unmagic = image.width
          self.image_height_unmagic = image.height
        end
        errors.add(:image, 'must be at least 992px wide') if image_width_unmagic < 800 # legacy images are 800px
        errors.add(:image, 'must be more wide than high') if image_height_unmagic > image_width_unmagic
      rescue StandardError, Dragonfly::Shell::CommandFailed
        errors.add(:image, 'is not supported or corrupted')
      end
    end
  end

  # The event's caches change with $addToSet and $pull rather than by writing back arrays from the event in hand, which
  # can be a copy loaded before another admin's change to its co-hosts, and writing back its arrays would undo that
  after_create do
    event.add_to_set(cohosts_ids_cache: organisation_id, hosts_ids_cache: organisation_id)
    event.sync_carousel_ids!
  end

  after_destroy do
    event.pull(cohosts_ids_cache: organisation_id)
    # An old co-hostship of the host's own organisation (no longer allowed) leaves it among the hosts
    event.pull(hosts_ids_cache: organisation_id) unless organisation_id == event.organisation_id
    event.sync_carousel_ids! unless event.flagged_for_destroy?
  end

  validates_uniqueness_of :event, scope: :organisation
end
