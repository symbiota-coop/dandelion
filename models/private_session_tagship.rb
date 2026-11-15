class PrivateSessionTagship
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :private_session
  belongs_to_without_parent_validation :private_session_tag

  validates_uniqueness_of :private_session_tag, scope: :private_session

  def private_session_tag_name
    private_session_tag.name
  end
end
