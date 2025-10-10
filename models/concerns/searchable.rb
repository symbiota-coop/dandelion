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
        # Ensure text index exists before performing text search
        ensure_text_index

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

    def ensure_text_index
      return if @text_index_created

      begin
        # Create a compound text index on all search fields
        index_spec = search_fields.each_with_object({}) { |field, hash| hash[field] = 'text' }
        collection.indexes.create_one(index_spec)
        @text_index_created = true
      rescue Mongo::Error::OperationFailure => e
        # Index might already exist, which is fine
        @text_index_created = true unless e.message.include?('IndexOptionsConflict')
        raise e if e.message.include?('IndexOptionsConflict')
      end
    end
  end
end
