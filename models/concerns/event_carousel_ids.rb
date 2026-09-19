module EventCarouselIds
  extend ActiveSupport::Concern

  def sync_carousel_ids!
    return if flagged_for_destroy?

    org_ids = [organisation_id, *(cohosts_ids_cache || [])].compact
    tag_ids = EventTagship.and(event_id: id).pluck(:event_tag_id)
    ids = if org_ids.any? && tag_ids.any?
            Carousel.and(:organisation_id.in => org_ids, :id.in => Carouselship.and(:event_tag_id.in => tag_ids).pluck(:carousel_id)).pluck(:id)
          else
            []
          end
    set(carousel_ids: ids)
  end
end
