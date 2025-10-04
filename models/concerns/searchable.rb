module Searchable
  extend ActiveSupport::Concern

  class_methods do
    def search(query, scope = nil)
      return none if query.blank?

      # Query length validation: 3-200 characters
      return none if query.length < 3 || query.length > 200

      query = "\"#{query.strip}\""

      if Padrino.env == :development
        self.or(search_fields.map { |field| { field => /#{Regexp.escape(query)}/i } })
      else
        pipeline = [
          { '$match': { '$text': { '$search': query } } }
        ]

        # Handle scope parameter: can be a Mongoid scope or an Array of models
        if scope
          if scope.respond_to?(:selector)
            # Mongoid scope - use its selector
            pipeline << { '$match': scope.selector }
          elsif scope.is_a?(Array)
            # Array of models - extract IDs and match against them
            if scope.empty?
              return none  # No results if array is empty
            else
              ids = scope.map { |item| item.respond_to?(:id) ? item.id : item }
              pipeline << { '$match': { '_id': { '$in': ids } } }
            end
          end
        end
        
        pipeline << { '$project': { _id: 1 } }

        collection.aggregate(pipeline).map { |doc| { id: doc[:_id] } }
      end
    end

    def search_fields
      raise NotImplementedError, "#{self} must implement search_fields class method"
    end
  end
end
