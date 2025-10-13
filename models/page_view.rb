class PageView
  include Mongoid::Document
  include Mongoid::Timestamps
  include DandelionMongo

  field :path, type: String
  field :query_string, type: String

  def self.admin_fields
    {
      path: :text,
      query_string: :text
    }
  end
end
