class PageView
  include Mongoid::Document
  include Mongoid::Timestamps

  field :path, type: String
  index({ path: 1 })
  field :query_string, type: String
  index({ location: 1 })

  def self.admin_fields
    {
      path: :text,
      query_string: :text
    }
  end
end
