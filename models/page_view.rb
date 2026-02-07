class PageView
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions
  include RequestFields

  def self.admin_fields
    RequestFields.admin_fields
  end
end
