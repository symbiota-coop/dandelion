class DragonflyJob
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  extend Dragonfly::Model

  field :signature, type: String
  field :uid, type: String

  def self.admin_fields
    {
      signature: :text,
      uid: :text
    }
  end

  validates_presence_of :signature, :uid
  validates_uniqueness_of :signature, :uid
end
