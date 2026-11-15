class PrivateSessionTag
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  field :name, type: String

  validates_uniqueness_of :name

  has_many :private_session_tagships, dependent: :destroy
  has_many_through :private_sessions, through: :private_session_tagships

  before_validation do
    self.name = name.downcase if name
  end

  # Suggestions for the tags select: the tags private sessions use
  def self.for_select
    PrivateSessionTag.and(:id.in => PrivateSessionTagship.pluck(:private_session_tag_id)).pluck(:name).sort
  end

  # The tags of listed sessions, for filtering the list by
  def self.in_use
    PrivateSessionTag.and(:id.in => PrivateSessionTagship.and(:private_session_id.in => PrivateSession.listed.pluck(:id)).pluck(:private_session_tag_id)).order('name asc')
  end
end
