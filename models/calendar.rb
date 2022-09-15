class Calendar
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :account

  field :url, type: String

  def self.admin_fields
    {
      url: :url,
      account_id: :lookup
    }
  end

  before_validation do
    begin
      open(url)
    rescue StandardError
      errors.add(:url, 'is invalid')
    end
  end

  validates_presence_of :url
  validates_uniqueness_of :url, scope: :account

  def events
    RiCal.parse(open(url)).first.events.select { |e| e.dtstart > Time.now }.sort_by { |e| e.dtstart }
  end
end
