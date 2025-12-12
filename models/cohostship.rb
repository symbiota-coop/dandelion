class Cohostship
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  extend Dragonfly::Model
  include ImageWithValidation

  belongs_to_without_parent_validation :event, index: true
  belongs_to_without_parent_validation :organisation, index: true

  field :image_uid, type: String
  field :image_width_unmagic, type: Integer
  field :image_height_unmagic, type: Integer
  field :has_image, type: Boolean
  field :featured, type: Boolean

  def self.admin_fields
    {
      image: :image,
      featured: :checkbox,
      event_id: :lookup,
      organisation_id: :lookup
    }
  end

  before_validation do
    if image
      begin
        self.image_width_unmagic = image.width
        self.image_height_unmagic = image.height
        errors.add(:image, 'must be at least 992px wide') if image_width_unmagic < 800 # legacy images are 800px
        errors.add(:image, 'must be more wide than high') if image_height_unmagic > image_width_unmagic
      rescue StandardError, Dragonfly::Shell::CommandFailed
        errors.add(:image, 'is not supported or corrupted')
      end
    end
  end

  after_create do
    event.set(cohosts_ids_cache: ((event.cohosts_ids_cache || []) + [organisation.id]).uniq)
  end

  after_destroy do
    event.set(cohosts_ids_cache: (event.cohosts_ids_cache || []) - [organisation.id])
  end

  validates_uniqueness_of :event, scope: :organisation
end
