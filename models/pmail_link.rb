class PmailLink
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  DEVICE_CLICK_FIELDS = {
    'desktop' => :desktop_clicks,
    'mobile' => :mobile_clicks,
    'tablet' => :tablet_clicks
  }.freeze

  belongs_to_without_parent_validation :pmail

  field :url, type: String
  field :clicks, type: Integer
  field :desktop_clicks, type: Integer
  field :mobile_clicks, type: Integer
  field :tablet_clicks, type: Integer
  field :other_clicks, type: Integer

  validates_presence_of :url

  before_validation do
    if url
      uri = begin; URI.parse(url); rescue StandardError; nil; end
      errors.add(:url, 'is invalid') unless uri.is_a?(URI::HTTP) && uri.host.present?
      errors.add(:url, 'cannot contain sign_in_token') if url.include?('sign_in_token=')
    end
  end

  def record_click!(device_type: nil)
    field = DEVICE_CLICK_FIELDS[device_type.to_s] || :other_clicks
    inc(clicks: 1, field => 1)
  end

  def phone_clicks
    mobile_clicks.to_i + tablet_clicks.to_i
  end

  def device_breakdown?
    desktop_clicks.to_i.positive? || phone_clicks.positive?
  end

  def event
    return unless url

    uri = URI.parse(url)
    result = "#{uri.scheme}://#{uri.host}#{uri.path}"

    return unless (match = result.match(%r{\A#{ENV['BASE_URI']}/e/([a-z0-9-]+)\Z}))

    Event.find_by(slug: match[1])
  end
end
