class Photo
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  extend Dragonfly::Model
  include ImageWithValidation

  belongs_to_without_parent_validation :photoable, polymorphic: true
  belongs_to_without_parent_validation :account

  field :image_uid, type: String
  field :has_image, type: Boolean

  def self.admin_fields
    {
      image: :image,
      photoable_id: :text,
      photoable_type: :select
    }
  end

  def self.photoables
    %w[Gathering Comment TicketType]
  end

  def url
    case photoable
    when Gathering
      gathering = photoable
      "#{ENV['BASE_URI']}/g/#{gathering.slug}#photo-#{id}"
    when Comment
      comment = photoable
      comment.post.url
    when TicketType
      ticket_type = photoable
      "#{ENV['BASE_URI']}/events/#{ticket_type.event_id}/ticket_types"
    end
  end

  validates_presence_of :image
end
