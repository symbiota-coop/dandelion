module EventScopes
  extend ActiveSupport::Concern

  class_methods do
    def course
      self.and(:id.in =>
        EventTagship.and(:event_tag_id.in =>
          EventTag.and(:name.in => %w[course courses]).pluck(:id)).pluck(:event_id))
    end

    def future(from = Date.today)
      self.and(:start_time.gte => from).order('start_time asc')
    end

    def current(from = Date.today)
      self.and(:end_time.gte => from).order('start_time asc')
    end

    def future_and_current_featured(from = Date.today)
      self.and(:id.in => future(from).pluck(:id) + current(from).and(featured: true).pluck(:id)).order('start_time asc')
    end

    def future_and_current(from = Date.today)
      self.and(:id.in => future(from).pluck(:id) + current(from).pluck(:id)).order('start_time asc')
    end

    def past(from = Date.today)
      self.and(:start_time.lt => from).order('start_time desc')
    end

    def finished(from = Date.today)
      self.and(:end_time.lt => from).order('start_time desc')
    end

    def online
      self.and(location: 'Online')
    end

    def legit
      events_with_tickets = TicketType.pluck(:event_id)
      events_by_paid_up_orgs = Event.and(:organisation_id.in => Organisation.and(paid_up: true).pluck(:id)).pluck(:id)

      self
        .and(:organisation_id.in => Organisation.and(:hidden.ne => true).pluck(:id))
        .and(:id.in => (events_with_tickets + events_by_paid_up_orgs))
    end

    def locked
      self.and(locked: true)
    end

    def live
      self.and(:locked.ne => true).and(:organisation_id.ne => nil)
    end

    def secret
      self.and(secret: true)
    end

    def in_person
      self.and(:location.ne => 'Online')
    end

    def trending(from = Date.today)
      live.public.legit.future(from).and(:image_uid.ne => nil, :hide_from_trending.ne => true).and(
        :organisation_id.in => Organisation.and(paid_up: true).pluck(:id)
      ).sort_by do |event|
        [event.trending ? 0 : 1, -event.orders.complete.and(:created_at.gt => from - 1.week).count]
      end
    end
  end
end
