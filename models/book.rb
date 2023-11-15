class Book
  include Mongoid::Document
  include Mongoid::Timestamps

  field :title, type: String

  belongs_to :book_author, index: true

  has_many :book_chapters, dependent: :destroy

  def self.admin_fields
    {
      title: :text,
      book_author_id: :lookup,
      book_chapters: :collection
    }
  end

  validates_presence_of :title
end
