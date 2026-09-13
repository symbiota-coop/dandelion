module EventCarouselIds
  extend ActiveSupport::Concern

  class_methods do
    def refresh_carousel_ids!
      Event.collection.update_many(
        { 'carousel_ids' => { '$exists' => true, '$ne' => [] } },
        { '$set' => { 'carousel_ids' => [] } }
      )

      Carousel.each do |carousel|
        tag_ids = carousel.event_tag_ids
        next if tag_ids.empty? || !carousel.organisation

        event_ids = EventTagship.and(:event_tag_id.in => tag_ids).only(:event_id).pluck(:event_id)
        next if event_ids.empty?

        ids = carousel.organisation.events_including_cohosted.and(:id.in => event_ids).pluck(:id)
        next if ids.empty?

        Event.collection.update_many(
          { '_id' => { '$in' => ids } },
          { '$addToSet' => { 'carousel_ids' => carousel.id } }
        )
      end
    end
  end
end
