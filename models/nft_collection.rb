class NftCollection
  include Mongoid::Document
  include Mongoid::Timestamps

  has_many :nfts, dependent: :destroy

  field :name, type: String
  field :prompt, type: String
  field :crossmint_id, type: String

  def self.admin_fields
    {
      name: :text,
      prompt: :text_area,
      crossmint_id: :text,
      nfts: :collection
    }
  end
end
