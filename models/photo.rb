class Photo
  include Mongoid::Document
  include Mongoid::Timestamps
  extend Dragonfly::Model

  belongs_to :photoable, polymorphic: true, index: true
  belongs_to :account, index: true

  field :image_uid, type: String

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

  def url
    if photoable.is_a?(Gathering)
      gathering = photoable
      "#{ENV['BASE_URI']}/g/#{gathering.slug}#photo-#{id}"
    elsif photoable.is_a?(Comment)
      comment = photoable
      comment.post.url
    elsif photoable.is_a?(TicketType)
      ticket_type = photoable
      "#{ENV['BASE_URI']}/events/#{ticket_type.event_id}/ticket_types"
    end
  end

  validates_presence_of :image
end
