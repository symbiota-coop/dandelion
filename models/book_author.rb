class BookAuthor
  include Mongoid::Document
  include Mongoid::Timestamps

  field :name, type: String

  has_many :books, dependent: :nullify

  def self.admin_fields
    {
      name: :text,
      books: :collection
    }
  end

  validates_presence_of :name
end
