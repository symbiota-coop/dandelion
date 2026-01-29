class PageView
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions
  include RequestFields

  index({ created_at: 1 }, { expire_after_seconds: 30.days.to_i })

  def self.admin_fields
    RequestFields.admin_fields
  end
end
