module Searchable
  extend ActiveSupport::Concern

  class_methods do
    def search(query, all_fields: false)
      return none if query.blank?

      # Bot protection: reject queries with newlines
      return none if query.include?("\n") || query.include?("\r")
      # Query length validation: 3-200 characters
      return none if query.length < 3 || query.length > 200

      if Padrino.env == :development
        search_paths = search_fields
        self.or(search_paths.map { |field| { field => /#{Regexp.escape(query)}/i } })
      else
        pipeline = [
          {
            '$search' => {
              'index' => to_s.underscore.pluralize,
              'text' => {
                'query' => query,
                'path' => search_fields
              }
            }
          }
        ]

        unless all_fields
          pipeline << {
            '$project' => {
              '_id' => 1
            }
          }
        end

        results = collection.aggregate(pipeline)

        results.map do |hash|
          new(hash.select { |k, _v| fields.keys.include?(k.to_s) })
        end
      end
    end

    def search_fields
      raise NotImplementedError, "#{self} must implement search_fields class method"
    end
  end
end
