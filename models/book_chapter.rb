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
      number: :text,
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

  def self.sorted
    all.sort_by do |book_chapter|
      book_chapter.number.split('.').map(&:to_i)
    end
  end

  def previous
    sorted_chapters = book.book_chapters.sorted
    current_index = sorted_chapters.pluck(:id).index(id)
    current_index > 0 ? sorted_chapters[current_index - 1] : nil
  end

  def next
    sorted_chapters = book.book_chapters.sorted
    current_index = sorted_chapters.pluck(:id).index(id)
    current_index < sorted_chapters.count - 1 ? sorted_chapters[current_index + 1] : nil
  end
end
