module Searchable
  extend ActiveSupport::Concern

  class_methods do
    def search(query, scope = nil)
      return none if query.blank?
      return none if query.length < 3 || query.length > 200

      if Padrino.env == :development
        where('$or' => search_fields.map { |field| { field => /#{Regexp.escape(query)}/i } })
      else
        query = "\"#{query.strip}\""

        pipeline = [
          { '$match': { '$text': { '$search': query } } }
        ]

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
