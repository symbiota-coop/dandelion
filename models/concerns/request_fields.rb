module RequestFields
  extend ActiveSupport::Concern

  included do
    field :path, type: String
    field :query_string, type: String
    field :user_agent, type: String
    field :referrer, type: String
    field :ip, type: String
    field :country, type: String
    field :x_requested_with, type: String

    attr_accessor :request

    before_validation :set_fields_from_request
  end

  def set_fields_from_request
    return unless request

    self.path = request.path
    self.query_string = request.query_string
    self.user_agent = request.user_agent
    self.referrer = request.referrer
    self.ip = request.env['HTTP_CF_CONNECTING_IP'] || request.env['HTTP_X_FORWARDED_FOR'] || request.ip
    self.country = request.env['HTTP_CF_IPCOUNTRY']
    self.x_requested_with = request.env['HTTP_X_REQUESTED_WITH']
  end

end
