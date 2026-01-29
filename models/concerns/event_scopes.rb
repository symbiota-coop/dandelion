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
      self.and(:end_time.gte => from).order('start_time asc')
    end

    def future_and_current_featured(from = Date.today)
      self.and('$or' => [
                 { start_time: { '$gte' => from } },
                 { end_time: { '$gte' => from }, featured: true }
               ]).order('start_time asc')
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

    def in_person
      self.and(:location.ne => 'Online')
    end

    def trending(from = Date.today)
      # If this is being called on an existing query, use that; otherwise use the default trending filters
      base_query = if self == Event
                     # Called as Event.trending - apply default filters
                     live.public.browsable.future(from).and(has_image: true).and(hidden_from_homepage: false)
                   else
                     # Called as a chain like @events.trending - use the existing query
                     self
                   end

      # Use aggregation pipeline for the complex sorting
      collection.aggregate([
                             # Match the IDs from our filtered query
                             { '$match' => { '_id' => { '$in' => base_query.pluck(:id) } } },
                             # Lookup recent orders for sorting
                             {
                               '$lookup' => {
                                 'from' => 'orders',
                                 'let' => { 'event_id' => '$_id' },
                                 'pipeline' => [
                                   {
                                     '$match' => {
                                       '$expr' => { '$eq' => ['$event_id', '$$event_id'] },
                                       'payment_completed' => true,
                                       'created_at' => { '$gt' => from - 1.week }
                                     }
                                   },
                                   { '$count' => 'count' }
                                 ],
                                 'as' => 'recent_orders'
                               }
                             },
                             # Sort by trending status first, then by recent order count
                             {
                               '$addFields' => {
                                 'trending_priority' => { '$cond' => [{ '$eq' => ['$trending', true] }, 0, 1] },
                                 'recent_order_count' => {
                                   '$cond' => [
                                     { '$gt' => [{ '$size' => '$recent_orders' }, 0] },
                                     { '$arrayElemAt' => ['$recent_orders.count', 0] },
                                     0
                                   ]
                                 }
                               }
                             },
                             { '$sort' => { 'trending_priority' => 1, 'recent_order_count' => -1 } },
                             { '$unset' => %w[recent_orders trending_priority recent_order_count] }
                           ]).map { |hash| Event.new(hash.select { |k, _v| Event.fields.keys.include?(k.to_s) }) }
    end
  end
end
