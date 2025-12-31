module EventSerialization
  extend ActiveSupport::Concern

  class_methods do
    def with_public_includes
      includes(:activity, :local_group, cohostships: :organisation, event_facilitations: :account, event_tagships: :event_tag)
    end

    def to_public_json
      with_public_includes.map(&:public_data).to_json
    end

    def to_public_xml
      with_public_includes.map(&:public_data).to_xml(root: 'events')
    end
  end

  def public_data
    {
      id: id.to_s,
      slug: slug,
      name: name,
      cohosts: cohostships.map { |cohostship| { name: cohostship.organisation.name, slug: cohostship.organisation.slug } },
      facilitators: event_facilitations.map { |event_facilitation| { name: event_facilitation.account.name, username: event_facilitation.account.username } },
      activity: activity ? { name: activity.name, id: activity_id.to_s } : nil,
      local_group: local_group ? { name: local_group.name, id: local_group_id.to_s } : nil,
      email: email,
      tags: event_tagships.map(&:event_tag_name),
      start_time: start_time,
      end_time: end_time,
      location: location,
      time_zone: time_zone,
      image: image ? image.thumb('1920x1920').url : nil,
      description: description
    }
  end

  def to_public_xml
    public_data.to_public_xml
  end

  def to_public_json
    public_data.to_public_json
  end
end
