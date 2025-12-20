class AccountRecommendationCache
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

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
    people = Hash.new { |h, k| h[k] = [] }

    # Get connections from past events - batch fetch all attendees at once
    event_ids = account.tickets.pluck(:event_id)
    events = Event.past.and(:id.in => event_ids).only(:id)

    # Batch fetch all tickets for these events in a single query
    event_attendees = Ticket.and(:event_id.in => events.pluck(:id), payment_completed: true)
                            .pluck(:event_id, :account_id)
                            .group_by(&:first)
                            .transform_values { |pairs| pairs.map(&:last).uniq }

    event_attendees.each do |event_id, attendee_ids|
      event_id_str = event_id.to_s
      attendee_ids.each do |attendee_id|
        next if attendee_id == account_id

        people[attendee_id.to_s] << { type: 'Event', id: event_id_str }
      end
    end

    # Get connections from gatherings - batch fetch all members at once
    gathering_ids = account.memberships.pluck(:gathering_id)

    gathering_members = Membership.and(:gathering_id.in => gathering_ids)
                                  .pluck(:gathering_id, :account_id)
                                  .group_by(&:first)
                                  .transform_values { |pairs| pairs.map(&:last).uniq }

    gathering_members.each do |gathering_id, member_ids|
      gathering_id_str = gathering_id.to_s
      member_ids.each do |member_id|
        next if member_id == account_id

        people[member_id.to_s] << { type: 'Gathering', id: gathering_id_str }
      end
    end

    sorted_people = people.sort_by { |_k, v| -v.size }
    set(recommended_people_cache: sorted_people)
  end

  def recommend_events!(events_with_participant_ids, people)
    my_account_id_str = account_id.to_s

    events = events_with_participant_ids.filter_map do |event_id, participant_ids|
      next if participant_ids.include?(my_account_id_str)

      # Use Set intersection for O(n) instead of O(n*m)
      participant_set = participant_ids.to_set
      matching_people = people.to_h.slice(*participant_set)
      [event_id, matching_people]
    end

    # Filter and sort with cached connection counts
    events = events.map do |event_id, matching_people|
      connections = matching_people.values.flatten
      next if connections.empty?

      [event_id, matching_people, connections.size]
    end.compact

    # Sort by connection count descending, then remove the count from output
    events = events.sort_by { |_event_id, _people, count| -count }
                   .map { |event_id, matching_people, _count| [event_id, matching_people] }

    set(recommended_events_cache: events)
  end
end
