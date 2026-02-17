class PageView
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions
  include RequestFields

end
