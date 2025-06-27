class AccountCache
  include Mongoid::Document
  include Mongoid::Timestamps

  field :recommended_people_cache, type: Array
  field :recommended_events_cache, type: Array

  belongs_to :account, index: true

  def self.admin_fields
    {
      recommended_people_cache: { type: :text_area, disabled: true },
      recommended_events_cache: { type: :text_area, disabled: true },
      account_id: :lookup
    }
  end

  def recommend_people!
    events = Event.past.and(:id.in => account.tickets.pluck(:event_id))
    people = {}
    events.each do |event|
      event.attendees.pluck(:id).each do |attendee_id|
        next if attendee_id == account_id

        if people[attendee_id.to_s]
          people[attendee_id.to_s] << event.id.to_s
        else
          people[attendee_id.to_s] = [event.id.to_s]
        end
      end
    end
    people = people.sort_by { |_k, v| -v.count }
    update_attribute(:recommended_people_cache, people)
  end

  def recommend_events!(events_with_participant_ids, people)
    events = events_with_participant_ids.map do |event_id, participant_ids|
      if participant_ids.include?(id.to_s)
        nil
      else
        [event_id, people.select { |k, _v| participant_ids.include?(k) }]
      end
    end.compact
    events = events.select { |_event_id, people| people.map { |_k, v| v }.flatten.count > 0 }
    events = events.sort_by { |_event_id, people| -people.map { |_k, v| v }.flatten.count }
    update_attribute(:recommended_events_cache, events)
  end
end
