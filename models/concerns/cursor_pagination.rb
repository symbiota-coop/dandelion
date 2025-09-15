module CursorPagination
  extend ActiveSupport::Concern

  class_methods do
    # Cursor-based pagination using a combination of sort field and _id
    # This completely eliminates the need for skip!
    def paginate_by_cursor(sort_field: :start_time, sort_direction: :asc, cursor: nil, limit: 20)
      query = self
      
      if cursor
        cursor_data = decode_cursor(cursor)
        if cursor_data
          sort_value = cursor_data[:sort_value]
          last_id = cursor_data[:id]
          
          # Build the cursor condition based on sort direction
          if sort_direction == :asc
            # For ascending: get records after the cursor
            query = query.or(
              { sort_field => { '$gt' => sort_value } },
              { sort_field => sort_value, :_id => { '$gt' => last_id } }
            )
          else
            # For descending: get records before the cursor
            query = query.or(
              { sort_field => { '$lt' => sort_value } },
              { sort_field => sort_value, :_id => { '$lt' => last_id } }
            )
          end
        end
      end
      
      # Apply sort and limit
      query = query.order(sort_field => sort_direction, :_id => sort_direction).limit(limit + 1)
      
      # Fetch records
      records = query.to_a
      has_next = records.length > limit
      records = records.first(limit) if has_next
      
      # Generate next cursor if there are more records
      next_cursor = if has_next && records.any?
        last_record = records.last
        encode_cursor(
          sort_value: last_record.send(sort_field),
          id: last_record.id
        )
      end
      
      {
        records: records,
        next_cursor: next_cursor,
        has_next: has_next
      }
    end
    
    # Alternative: Keyset pagination for numeric offsets (better than skip but not as good as cursor)
    def paginate_keyset(page: 1, per_page: 20, sort_field: :start_time, sort_direction: :asc)
      # Cache the boundary values for common page sizes
      cache_key = "#{collection_name}_keyset_#{sort_field}_#{sort_direction}_p#{page}_pp#{per_page}"
      
      boundary = Rails.cache.fetch(cache_key, expires_in: 5.minutes) do
        offset = (page - 1) * per_page
        
        if offset > 0
          # Use aggregation to efficiently find the boundary document
          result = collection.aggregate([
            { '$match' => selector },
            { '$sort' => { sort_field => (sort_direction == :asc ? 1 : -1), '_id' => 1 } },
            { '$skip' => offset - 1 },
            { '$limit' => 1 },
            { '$project' => { sort_field => 1, '_id' => 1 } }
          ]).first
          
          result if result
        end
      end
      
      query = self
      
      if boundary
        # Use the boundary to avoid skip
        if sort_direction == :asc
          query = query.and(
            '$or' => [
              { sort_field => { '$gt' => boundary[sort_field.to_s] } },
              { sort_field => boundary[sort_field.to_s], :_id => { '$gt' => boundary['_id'] } }
            ]
          )
        else
          query = query.and(
            '$or' => [
              { sort_field => { '$lt' => boundary[sort_field.to_s] } },
              { sort_field => boundary[sort_field.to_s], :_id => { '$lt' => boundary['_id'] } }
            ]
          )
        end
      end
      
      query.order(sort_field => sort_direction, :_id => sort_direction).limit(per_page)
    end
    
    private
    
    def encode_cursor(data)
      Base64.urlsafe_encode64(data.to_json)
    end
    
    def decode_cursor(cursor)
      JSON.parse(Base64.urlsafe_decode64(cursor)).symbolize_keys
    rescue StandardError
      nil
    end
  end
  
  # Instance methods for generating cursors from records
  included do
    def to_cursor(sort_field = :start_time)
      Base64.urlsafe_encode64({
        sort_value: send(sort_field),
        id: id.to_s
      }.to_json)
    end
  end
end