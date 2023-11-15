class Book
  include Mongoid::Document
  include Mongoid::Timestamps
  extend Dragonfly::Model

  field :title, type: String
  field :slug, type: String
  field :image_uid, type: String

  belongs_to :book_author, index: true

  has_many :book_chapters, dependent: :destroy

  def self.admin_fields
    {
      title: :text,
      slug: :slug,
      image: :image,
      book_author_id: :lookup,
      book_chapters: :collection
    }
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

  validates_presence_of :title
end
