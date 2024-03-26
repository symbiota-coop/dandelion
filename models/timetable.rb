class Timetable
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :gathering, index: true
  belongs_to :account, index: true

  field :name, type: String
  field :description, type: String
  field :hide_schedule, type: Boolean
  field :scheduling_by_all, type: Boolean

  def self.admin_fields
    {
      name: :text,
      description: :wysiwyg,
      hide_schedule: :check_box,
      scheduling_by_all: :check_box,
      gathering_id: :lookup,
      account_id: :lookup,
      spaces: :collection,
      tslots: :collection,
      tactivities: :collection
    }
  end

  validates_presence_of :name

  has_many :spaces, dependent: :destroy
  has_many :tslots, dependent: :destroy
  has_many :tactivities, dependent: :destroy

  has_many :notifications, as: :notifiable, dependent: :destroy
  after_create do
    notifications.create! circle: circle, type: 'created_timetable'
  end

  def circle
    gathering
  end

  def self.new_hints
    {
      scheduling_by_all: 'By default, only admins can schedule activities'
    }
  end

  def self.edit_hints
    {}.merge(new_hints)
  end

  def self.human_attribute_name(attr, options = {})
    {
      scheduling_by_all: 'Allow all members to schedule activities'
    }[attr.to_sym] || super
  end
end
