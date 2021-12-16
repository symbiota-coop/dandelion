class HabitCompletion
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :account, index: true
  belongs_to :habit, index: true

  field :date, type: Date
  field :comment, type: String

  def self.admin_fields
    {
      date: :date,
      comment: :text,
      account_id: :lookup,
      habit_id: :lookup
    }
  end

  has_many :habit_completion_likes, dependent: :destroy

  validates_presence_of :date, :account, :habit
  validates_uniqueness_of :habit, scope: [:account, :date]

  before_validation do
    self.account = habit.account if habit
  end
end
