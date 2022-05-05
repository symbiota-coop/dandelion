class Habit
  include Mongoid::Document
  include Mongoid::Timestamps
  extend Dragonfly::Model

  belongs_to :account, index: true

  field :name, type: String
  field :notes, type: String
  field :public, type: Boolean
  field :archived, type: Boolean
  field :o, type: Integer
  field :image_uid, type: String

  def self.admin_fields
    {
      name: :text,
      notes: :text_area,
      o: :number,
      public: :check_box,
      archived: :check_box,
      account_id: :lookup
    }
  end

  has_many :habit_completions, dependent: :destroy

  has_many :posts, as: :commentable, dependent: :destroy
  has_many :subscriptions, as: :commentable, dependent: :destroy
  has_many :comments, as: :commentable, dependent: :destroy
  has_many :comment_reactions, as: :commentable, dependent: :destroy

  validates_presence_of :name

  dragonfly_accessor :image
  before_validation do
    if image
      begin
        %w[jpeg png gif pam].include?(image.format)
      rescue StandardError
        self.image = nil
        errors.add(:image, 'must be an image')
      end
    end
  end

  def self.new_tips
    {
      notes: 'Notes are private and visible only to you',
      public: 'Make this habit visible on your profile'
    }
  end

  def self.human_attribute_name(attr, options = {})
    {
      image_url: 'Image URL'
    }[attr.to_sym] || super
  end

  def self.edit_tips
    new_tips
  end

  def discussers
    account.discussers
  end
end
