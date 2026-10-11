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

    def future_and_current(from = Date.today)
      self.and('$or' => [
                 { start_time: { '$gte' => from } },
                 { end_time: { '$gte' => from }, show_after_start_time: true }
               ]).order('start_time asc')
    end

    # Only use behind an organisation-, activity-, or local-group-scoped relation chain. Prefer future / future_and_current elsewhere
    def future_current_evergreen(from = Date.today)
      self.and('$or' => [
                 { start_time: { '$gte' => from } },
                 { end_time: { '$gte' => from }, show_after_start_time: true },
                 { evergreen: true }
               ]).order('start_time asc')
    end

    def past(from = Date.today)
      self.and(:start_time.lt => from, :evergreen => false).order('start_time desc')
    end

    def finished(from = Date.today)
      self.and(:end_time.lt => from, :evergreen => false).order('start_time desc')
    end

    def online
      self.and(location: 'Online')
    end

    def locked
      self.and(locked: true)
    end

    def browsable
      self.and(browsable: true)
    end

    def live
      self.and(locked: false).and(has_organisation: true)
    end

    def secret
      self.and(secret: true)
    end

    def without_heavy_fields
      without(:description, :extra_info_for_ticket_email, :voyage_embedding)
    end

    def in_person
      self.and(:location.ne => 'Online')
    end

    def trending(from = Date.today, limit: 100)
      base_query = if self == Event
                     live.publicly_visible.browsable.future(from).and(has_image: true).and(hidden_from_homepage: false)
                   else
                     self
                   end

      # Counts the week's paid orders by event, then ranks the few events that have any, rather than looking up the
      # orders of every upcoming event (about 5,000, for the homepage)
      recent_order_counts = Order.collection.aggregate([
                                                         { '$match' => { 'deleted_at' => nil, 'payment_completed' => true, 'created_at' => { '$gt' => from - 1.week } } },
                                                         { '$group' => { '_id' => '$event_id', 'count' => { '$sum' => 1 } } }
                                                       ]).to_h { |row| [row['_id'], row['count']] }

      ranked_ids = base_query.and('$or' => [{ trending: true }, { _id: { '$in' => recent_order_counts.keys } }])
                             .pluck(:id, :trending)
                             .sort_by { |id, trending| [trending ? 0 : 1, -recent_order_counts.fetch(id, 0)] }
                             .map(&:first)
      ranked_ids = ranked_ids.first(limit) if limit

      # Then the soonest of the rest
      unless limit && ranked_ids.length >= limit
        others = base_query.and(:id.nin => ranked_ids).order('start_time asc')
        others = others.limit(limit - ranked_ids.length) if limit
        ranked_ids += others.pluck(:id)
      end

      base_query.without(:voyage_embedding, :extra_info_for_ticket_email).with_key_includes.in_id_order(ranked_ids)
    end

    def in_id_order(ids)
      return [] if ids.empty?

      events_by_id = self.and(:id.in => ids).index_by { |event| event.id.to_s }
      ids.filter_map { |id| events_by_id[id.to_s] }
    end
  end
end
