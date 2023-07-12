class PmailLink
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :pmail, index: true

  field :url, type: String
  field :clicks, type: Integer

  def self.admin_fields
    {
      url: :url,
      clicks: :number,
      pmail_id: :lookup
    }
  end

  validates_presence_of :url

  before_validation do
    errors.add(:url, 'is invalid') if url && !URI::DEFAULT_PARSER.make_regexp.match(url)
    errors.add(:url, 'cannot contain sign_in_token') if url && url.include?('sign_in_token=')
  end

  def event
    return unless (m = url.match(%r{\A#{ENV['BASE_URI']}/e/([a-z0-9]+)\Z}))

    Event.find_by(slug: m[1])
  end
end
