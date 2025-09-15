module OptimizedPagination
  extend ActiveSupport::Concern
  
  class_methods do
    # Drop-in replacement for will_paginate that optimizes large skips
    def paginate_optimized(page: 1, per_page: 30)
      page = page.to_i
      per_page = per_page.to_i
      offset = (page - 1) * per_page
      
      # For small offsets, use regular skip (it's fine for < 1000)
      if offset < 1000
        return paginate(page: page, per_page: per_page)
      end
      
      # For large offsets, use range-based queries
      # This works best when you have a good index on the sort field
      sort_field = current_scope&.options&.dig(:sort)&.keys&.first || :_id
      sort_direction = current_scope&.options&.dig(:sort)&.values&.first || 1
      
      # Find the boundary document using aggregation (much faster than skip)
      boundary = collection.aggregate([
        { '$match' => selector },
        { '$sort' => { sort_field => sort_direction } },
        { '$skip' => offset },
        { '$limit' => 1 },
        { '$project' => { sort_field => 1 } }
      ]).first
      
      if boundary
        # Now query starting from that boundary
        if sort_direction == 1 # ascending
          where(sort_field => { '$gte' => boundary[sort_field.to_s] })
        else # descending
          where(sort_field => { '$lte' => boundary[sort_field.to_s] })
        end.limit(per_page)
      else
        # No results at this offset
        none
      end
    end
    
    # Batch processing for large datasets (avoids skip entirely)
    def find_in_batches_optimized(batch_size: 1000, sort_field: :_id)
      last_id = nil
      
      loop do
        query = self
        query = query.where(sort_field => { '$gt' => last_id }) if last_id
        
        batch = query.order(sort_field => :asc).limit(batch_size).to_a
        break if batch.empty?
        
        yield batch
        
        last_id = batch.last.send(sort_field)
        break if batch.size < batch_size
      end
    end
    
    # For APIs: Return page info without using count (which can be slow)
    def paginate_api(page: 1, per_page: 30, sort_field: :start_time, sort_direction: :asc)
      page = page.to_i
      per_page = per_page.to_i
      
      # Fetch one extra record to know if there's a next page
      records = order(sort_field => sort_direction)
                .skip((page - 1) * per_page)
                .limit(per_page + 1)
                .to_a
      
      has_next = records.size > per_page
      records = records.first(per_page)
      
      {
        data: records,
        pagination: {
          page: page,
          per_page: per_page,
          has_next: has_next,
          # Only provide count for first few pages (it's expensive)
          total: page <= 3 ? count : nil
        }
      }
    end
  end
end