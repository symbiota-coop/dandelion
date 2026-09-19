module EventCarouselIds
  extend ActiveSupport::Concern

  class_methods do
    def refresh_carousel_ids!
      Carousel.each do |carousel|
        tag_ids = carousel.event_tag_ids
        event_ids = EventTagship.and(:event_tag_id.in => tag_ids).only(:event_id).pluck(:event_id)
        ids = if carousel.organisation && event_ids.any?
                carousel.organisation.events_including_cohosted.and(:id.in => event_ids).pluck(:id)
              else
                []
              end

        Event.collection.update_many(
          { 'deleted_at' => nil, 'carousel_ids' => carousel.id, '_id' => { '$nin' => ids } },
          { '$pull' => { 'carousel_ids' => carousel.id } }
        )
        Event.collection.update_many(
          { 'deleted_at' => nil, '_id' => { '$in' => ids } },
          { '$addToSet' => { 'carousel_ids' => carousel.id } }
        ) if ids.any?
      end
    end
  end
end
