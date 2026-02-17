class DocPage
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  field :name, type: String
  field :slug, type: String
  field :body, type: String
  field :priority, type: Integer

  validates_presence_of :name, :slug
  validates_uniqueness_of :slug

end
