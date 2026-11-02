# Models whose URLs name them by a slug (an account's by its username). find_by_slug_or_id also takes an id in the
# slug's place, as links made before their URLs used slugs named them by id
module SlugLookup
  extend ActiveSupport::Concern

  class_methods do
    def slug_field
      :slug
    end

    def find_by_slug_or_id(slug: nil, id: nil)
      if id.present?
        find(id)
      elsif slug.present?
        # An id first, so a record whose slug is another's id can't take over that one's old links
        (find(slug) if BSON::ObjectId.legal?(slug)) || find_by(slug_field => slug)
      end
    end
  end
end
