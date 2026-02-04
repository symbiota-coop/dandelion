class ActivityTag
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  field :name, type: String

  def self.admin_fields
    {
      name: { type: :text, full: true }
    }
  end

  has_many :activity_tagships, dependent: :destroy
  has_many :pmails_as_mailable, class_name: 'Pmail', as: :mailable, dependent: :destroy

  validates_uniqueness_of :name

  def self.for_select
    ActivityTag.and(:id.in => ActivityTagship.pluck(:activity_tag_id)).order('name asc').pluck(:name).map { |name| Sanitize.fragment(name).gsub('&amp;', '&') }
  end

  def subscribed_members
    Account.and(:id.in => Activityship.and(:activity_id.in => activity_tagships.pluck(:activity_id)).and(unsubscribed: false).pluck(:account_id))
  end

  before_validation do
    self.name = name.downcase if name
  end
end
