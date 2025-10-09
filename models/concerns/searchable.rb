module Searchable
  extend ActiveSupport::Concern

  class_methods do
    def search(query, scope = nil)
      return none if query.blank?
      return none if query.length < 3 || query.length > 200

      # If query is an email address and model has an email field, search only email
      if query.match?(EMAIL_REGEX) && fields.key?('email')
        scope ||= all
        return scope.and(email: query)
      end

      if Padrino.env == :development
        scope ||= all
        scope.where('$or' => search_fields.map { |field| { field => /#{Regexp.escape(query)}/i } })
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
