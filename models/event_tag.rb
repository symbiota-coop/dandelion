class EventTag
  include Mongoid::Document
  include Mongoid::Timestamps
  include BelongsToWithoutParentValidation

  include Searchable

  field :name, type: String

  def self.admin_fields
    {
      name: { type: :text, full: true }
    }
  end

  def self.search_fields
    %w[name]
  end

  validates_uniqueness_of :name

  has_many :event_tagships, dependent: :destroy

  before_validation do
    self.name = name.downcase if name
  end

  def self.update_tags_for_select
    fragment = Fragment.find_or_create_by(key: 'event_tags_for_select')

    tag_counts = EventTagship.collection.aggregate([
                                                     { '$group': { _id: '$event_tag_id', count: { '$sum': 1 } } },
                                                     { '$sort': { count: -1 } },
                                                     { '$limit': 500 }
                                                   ]).to_a

    # Get the tag names for the top tags
    tag_ids = tag_counts.map { |doc| doc['_id'] }
    tags_by_id = EventTag.and(:id.in => tag_ids).pluck(:id, :name).to_h

    # Build sorted list alphabetically
    tag_names = tag_counts.map do |doc|
      tag_name = tags_by_id[doc['_id']]
      Sanitize.fragment(tag_name).gsub('&amp;', '&') if tag_name
    end.compact.sort

    fragment.update_attributes expires: 1.day.from_now, value: tag_names.to_json
  end

  def self.for_select
    fragment = Fragment.find_by(key: 'event_tags_for_select')
    fragment ? JSON.parse(fragment.value) : []
  end
end
