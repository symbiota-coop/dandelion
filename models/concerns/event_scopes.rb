module EventScopes
  extend ActiveSupport::Concern

  class_methods do
    def course
      self.and(:id.in =>
        EventTagship.and(:event_tag_id.in =>
          EventTag.and(:name.in => %w[course courses]).pluck(:id)).pluck(:event_id))
    end

    def future(from = Date.today)
      self.and('$or' => [
                 { :start_time.gte => from },
                 { evergreen: true }
               ]).order('start_time asc')
    end

    # Map JSON only plots coordinates; evergreen events never have a location, so start_time alone matches map-visible rows.
    def future_for_map(from = Date.today)
      self.and(:start_time.gte => from).order('start_time asc')
    end

    def future_and_current(from = Date.today)
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
      without(:description, :extra_info_for_ticket_email, :embedding)
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

      pipeline = [
        { '$match' => base_query.selector },
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
        { '$sort' => { 'trending_priority' => 1, 'recent_order_count' => -1 } }
      ]

      pipeline << { '$limit' => limit } if limit
      pipeline << { '$unset' => %w[recent_orders trending_priority recent_order_count embedding extra_info_for_ticket_email] }

      collection.aggregate(pipeline).map { |hash| Event.new(hash.select { |k, _v| Event.fields.keys.include?(k.to_s) }) }
    end
  end
end
