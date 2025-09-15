module Searchable
  extend ActiveSupport::Concern

  class_methods do
    def search(query)
      return none if query.blank?

      if Padrino.env == :development
        search_paths = search_fields
        self.or(search_paths.map { |field| { field => /#{Regexp.escape(query)}/i } })
      else
        index_name = to_s.underscore.pluralize
        search_paths = search_fields

        pipeline = [
          {
            '$search' => {
              'index' => index_name,
              'text' => {
                'query' => query,
                'path' => search_paths
              }
            }
          }
        ]

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
