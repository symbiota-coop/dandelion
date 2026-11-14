# Finding records nobody uses, for site admins to look over and delete (the Spring clean stats page)
module SpringCleaning
  extend ActiveSupport::Concern

  class_methods do
    # Those of scope that none of this model's has_many associations, but those in ignore, has anything in. One query
    # per association, for all of scope at once, rather than one per association for each record
    def without_associated(scope, ignore: [])
      ids = scope.pluck(:id)
      reflect_on_all_associations(:has_many).each do |association|
        break if ids.empty?
        next if ignore.include?(association.name)

        criteria = association.klass.and(association.foreign_key => { '$in' => ids })
        criteria = criteria.and(association.type => name) if association.polymorphic?
        ids -= criteria.distinct(association.foreign_key)
      end
      scope.and(:id.in => ids)
    end
  end
end
