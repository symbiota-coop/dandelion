class PmailLink
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :pmail

  field :url, type: String
  field :clicks, type: Integer

  validates_presence_of :url

  before_validation do
    errors.add(:url, 'is invalid') if url && !URI::DEFAULT_PARSER.make_regexp.match(url)
    errors.add(:url, 'cannot contain sign_in_token') if url && url.include?('sign_in_token=')
  end

  def event
    return unless url

    uri = URI.parse(url)
    result = "#{uri.scheme}://#{uri.host}#{uri.path}"

    return unless (match = result.match(%r{\A#{ENV['BASE_URI']}/e/([a-z0-9-]+)\Z}))

    Event.find_by(slug: match[1])
  end
end
