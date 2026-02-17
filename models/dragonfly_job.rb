class DragonflyJob
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  extend Dragonfly::Model

  field :signature, type: String
  field :uid, type: String

  validates_presence_of :signature, :uid
  validates_uniqueness_of :signature, :uid
end
