class EventTag < DandelionModel
  field :name, type: String

  def self.admin_fields
    {
      name: { type: :text, full: true }
    }
  end

  validates_uniqueness_of :name

  has_many :event_tagships, dependent: :destroy

  before_validation do
    self.name = name.downcase if name
  end

  def self.update_tags_for_select
    fragment = Fragment.find_or_create_by(key: 'event_tags_for_select')
    tag_names = EventTag.collection.aggregate([
                                                { '$lookup': { from: 'event_tagships', localField: '_id', foreignField: 'event_tag_id', as: 'tagships' } },
                                                { '$project': { name: 1, count: { '$size': '$tagships' } } },
                                                { '$match': { count: { '$gt': 0 } } },
                                                { '$sort': { count: -1, name: 1 } },
                                                { '$limit': 500 }
                                              ]).map do |doc|
      tag_name = doc['name']
      Sanitize.fragment(tag_name).gsub('&amp;', '&')
    end.sort
    fragment.update_attributes expires: 1.day.from_now, value: tag_names.to_json
  end

  def self.for_select
    fragment = Fragment.find_by(key: 'event_tags_for_select')
    fragment ? JSON.parse(fragment.value) : []
  end
end
