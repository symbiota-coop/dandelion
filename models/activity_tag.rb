class ActivityTag
  include Mongoid::Document
  include Mongoid::Timestamps

  field :name, type: String

  def self.admin_fields
    {
      name: { type: :text, full: true }
    }
  end

  has_many :activity_tagships, dependent: :destroy
  has_many :pmails_as_mailable, class_name: 'Pmail', as: :mailable, dependent: :destroy

  validates_uniqueness_of :name

  def subscribed_members
    Account.and(:id.in => Activityship.and(:activity_id.in => activity_tagships.pluck(:activity_id)).and(:unsubscribed.ne => true).pluck(:account_id))
  end

  before_validation do
    self.name = name.downcase if name
  end
end
