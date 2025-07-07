class Draft < DandelionModel
  belongs_to_without_parent_validation :account, index: true

  field :model, type: String
  field :name, type: String
  field :url, type: String
  field :json, type: String

  validates_presence_of :account, :model, :name, :url, :json

  before_create do
    Draft.and(account: account, model: model, name: name).destroy_all
  end

  def self.admin_fields
    {
      account_id: :lookup,
      model: :text,
      name: :text,
      url: :url,
      json: :text_area
    }
  end
end
