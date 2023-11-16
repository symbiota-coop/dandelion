class BookChapter
  include Mongoid::Document
  include Mongoid::Timestamps

  field :name, type: String
  field :summary, type: String
  field :number, type: String
  field :embedding, type: Array

  belongs_to :book, index: true

  def self.admin_fields
    {
      name: :text,
      number: :string,
      book_id: :lookup,
      summary: :text_area,
      embedding: { type: :text_area, disabled: true }
    }
  end

  validates_presence_of :name
  validates_uniqueness_of :number, scope: :book_id

  after_save :set_embedding
  def set_embedding
    client = OpenAI::Client.new
    response = client.embeddings(
      parameters: {
        model: 'text-embedding-ada-002',
        input: summary
      }
    )
    set(embedding: response.dig('data', 0, 'embedding'))
  end

  def previous
    book.book_chapters.find_by(number: number - 1)
  end

  def next
    book.book_chapters.find_by(number: number + 1)
  end
end
