class ActivityTagship
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :activity
  belongs_to_without_parent_validation :activity_tag

  validates_uniqueness_of :activity_tag, scope: :activity

  def activity_tag_name
    activity_tag.name
  end
end
