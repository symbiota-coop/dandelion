class PageView
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  field :path, type: String
  field :query_string, type: String

  index({ created_at: 1 }, { expire_after_seconds: 30.days.to_i })

  def self.admin_fields
    {
      path: :text,
      query_string: :text
    }
  end
end
