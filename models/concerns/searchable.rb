module Searchable
  extend ActiveSupport::Concern

  class_methods do
    def search(query, scope = nil)
      return none if query.blank?
      return none if query.length < 3 || query.length > 200

      query = "\"#{query.strip}\""

      if Padrino.env == :development
        self.or(search_fields.map { |field| { field => /#{Regexp.escape(query)}/i } })
      else
        begin
          pipeline = [
            { '$match': { '$text': { '$search': query } } }
          ]

          pipeline << { '$match': scope.selector } if scope
          pipeline << { '$project': { _id: 1 } }

          collection.aggregate(pipeline).map { |doc| { id: doc[:_id] } }
        rescue Mongo::Error::OperationFailure => e
          # Fall back to regex search if text index is not available
          if e.message.include?('text index required for $text query')
            # Remove quotes from query for regex search
            regex_query = query.gsub(/^"|"$/, '')
            self.or(search_fields.map { |field| { field => /#{Regexp.escape(regex_query)}/i } })
          else
            raise e
          end
        end
      end
    end

    def search_fields
      raise NotImplementedError, "#{self} must implement search_fields class method"
    end
  end
end
