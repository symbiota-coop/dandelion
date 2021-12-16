class Voption
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :comment, index: true
  belongs_to :account, index: true

  field :text, type: String

  def self.admin_fields
    {
      text: :text,
      account_id: :lookup
    }
  end

  has_many :votes, dependent: :destroy

  validates_presence_of :text
end
