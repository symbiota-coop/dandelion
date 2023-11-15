class BookChapter
  include Mongoid::Document
  include Mongoid::Timestamps

  field :name, type: String
  field :summary, type: String
  field :number, type: Integer
  field :embedding, type: Array

  belongs_to :book, index: true

  def self.admin_fields
    {
      name: :text,
      number: :number,
      summary: :text_area,
      book_id: :lookup,
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
end
