class Zoomship
  include Mongoid::Document
  include Mongoid::Timestamps
  include DandelionMongo

  belongs_to_without_parent_validation :event, index: true
  belongs_to_without_parent_validation :local_group, index: true
  belongs_to_without_parent_validation :account, index: true, optional: true

  field :link, type: String
  field :tickets_count, type: Integer

  def self.admin_fields
    {
      link: :url,
      tickets_count: :number,
      event_id: :lookup,
      local_group_id: :lookup,
      account_id: :lookup
    }
  end

  has_many :tickets, dependent: :destroy

  validates_presence_of :link
  validates_uniqueness_of :local_group, scope: :event
  validates_uniqueness_of :account, scope: :event, allow_nil: true

  before_validation do
    self.link = "https://meet.jit.si/#{SecureRandom.uuid}"
    self.tickets_count = 0 unless tickets_count
  end

  after_create do
    tickets.create(account: account, event: event, complementary: true) if account
  end
end
