class PageView
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  field :path, type: String
  field :query_string, type: String
  field :user_agent, type: String
  field :referrer, type: String
  field :ip, type: String
  field :x_requested_with, type: String

  attr_accessor :request

  index({ created_at: 1 }, { expire_after_seconds: 30.days.to_i })

  before_validation :set_fields_from_request

  def set_fields_from_request
    return unless request

    %i[path query_string user_agent referrer ip].each { |f| send("#{f}=", request.send(f)) }
    self.x_requested_with = request.env['HTTP_X_REQUESTED_WITH']
  end

  def self.admin_fields
    {
      path: :text,
      query_string: :text,
      user_agent: :text,
      referrer: :text,
      ip: :text,
      x_requested_with: :text
    }
  end
end
