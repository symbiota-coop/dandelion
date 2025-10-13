class AccountRecommendationCache
  include Mongoid::Document
  include Mongoid::Timestamps
  include DandelionMongo

  belongs_to_without_parent_validation :account, index: true

  validates_uniqueness_of :account

  field :recommended_people_cache, type: Array
  field :recommended_events_cache, type: Array

  def self.admin_fields
    {
      recommended_people_cache: { type: :text_area, disabled: true },
      recommended_events_cache: { type: :text_area, disabled: true },
      account_id: :lookup
    }
  end

  def recommend_people!
    # Get connections from past events
    events = Event.past.and(:id.in => account.tickets.pluck(:event_id))
    people = {}

    events.each do |event|
      event.attendees.pluck(:id).each do |attendee_id|
        next if attendee_id == account_id

        connection = { type: 'Event', id: event.id.to_s }
        if people[attendee_id.to_s]
          people[attendee_id.to_s] << connection
        else
          people[attendee_id.to_s] = [connection]
        end
      end
    end

    # Get connections from gatherings
    gatherings = Gathering.and(:id.in => account.memberships.pluck(:gathering_id))
    gatherings.each do |gathering|
      gathering.members.pluck(:id).each do |member_id|
        next if member_id == account_id

        connection = { type: 'Gathering', id: gathering.id.to_s }
        if people[member_id.to_s]
          people[member_id.to_s] << connection
        else
          people[member_id.to_s] = [connection]
        end
      end
    end

    people = people.sort_by { |_k, v| -v.count }
    update_attribute(:recommended_people_cache, people)
  end

  def recommend_events!(events_with_participant_ids, people)
    events = events_with_participant_ids.map do |event_id, participant_ids|
      if participant_ids.include?(account_id.to_s)
        nil
      else
        [event_id, people.select { |k, _v| participant_ids.include?(k) }]
      end
    end.compact
    events = events.select { |_event_id, people| people.map { |_k, v| v }.flatten.exists? }
    events = events.sort_by { |_event_id, people| -people.map { |_k, v| v }.flatten.count }
    update_attribute(:recommended_events_cache, events)
  end
end
