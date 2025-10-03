module Searchable
  extend ActiveSupport::Concern

  class_methods do
    def search(query, scope = nil)
      return none if query.blank?

      # Query length validation: 3-200 characters
      return none if query.length < 3 || query.length > 200

      if Padrino.env == :development
        search_paths = search_fields
        self.or(search_paths.map { |field| { field => /#{Regexp.escape(query)}/i } })
      else
        pipeline = [
          {
            '$search': {
              index: to_s.underscore.pluralize,
              phrase: {
                query: query,
                path: search_fields
              }
            }
          }
        ]

        # If a scope is passed, extract its selector and apply as $match
        pipeline << { '$match': scope.selector } if scope
        pipeline << { '$project': { _id: 1 } }

        collection.aggregate(pipeline).map { |doc| { id: doc[:_id] } }
      end
    end

    def search_fields
      raise NotImplementedError, "#{self} must implement search_fields class method"
    end
  end
end
