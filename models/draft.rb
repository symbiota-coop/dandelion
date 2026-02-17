class Draft
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :account

  field :model, type: String
  field :name, type: String
  field :url, type: String
  field :json, type: String

  validates_presence_of :account, :model, :name, :url, :json

  before_create do
    Draft.and(account: account, model: model, name: name).destroy_all
  end

end
