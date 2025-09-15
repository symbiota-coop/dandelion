# Optimizes will_paginate for MongoDB to handle large skip values efficiently
# This monkey patch intercepts paginate calls and uses cursor-based techniques for large offsets

module WillPaginate
  module Mongoid
    module CollectionMethods
      # Store the original paginate method
      alias_method :original_paginate, :paginate if method_defined?(:paginate)
      
      def paginate(options = {})
        options = options.dup
        page = options[:page] || 1
        per_page = options[:per_page] || WillPaginate.per_page
        
        page = page.to_i
        per_page = per_page.to_i
        offset = (page - 1) * per_page
        
        # Use optimization threshold from ENV or default to 1000
        threshold = ENV.fetch('PAGINATION_OPTIMIZATION_THRESHOLD', 1000).to_i
        
        # For small offsets, use the original implementation
        if offset < threshold
          return original_paginate(options) if respond_to?(:original_paginate)
          
          # Fallback to standard behavior if original_paginate doesn't exist
          WillPaginate::Collection.create(page, per_page) do |pager|
            items = limit(per_page).skip(offset).to_a
            pager.replace(items)
            pager.total_entries = count unless options[:total_entries]
          end
        else
          # For large offsets, use optimized approach
          paginate_optimized(options)
        end
      end
      
      private
      
      def paginate_optimized(options = {})
        page = options[:page] || 1
        per_page = options[:per_page] || WillPaginate.per_page
        
        page = page.to_i
        per_page = per_page.to_i
        offset = (page - 1) * per_page
        
        WillPaginate::Collection.create(page, per_page) do |pager|
          # Detect sort order from current scope
          sort_options = self.options[:sort] || { _id: 1 }
          sort_field = sort_options.keys.first
          sort_direction = sort_options.values.first
          
          # Strategy 1: Use cached boundaries for frequently accessed pages
          cache_key = "#{collection.name}_boundary_#{Digest::MD5.hexdigest(selector.to_json)}_#{sort_field}_#{sort_direction}_p#{page}_pp#{per_page}"
          
          boundary = Rails.cache.fetch(cache_key, expires_in: 10.minutes) do
            if offset > 0
              # Use aggregation to find the boundary document efficiently
              result = collection.aggregate([
                { '$match' => selector },
                { '$sort' => sort_options.transform_values { |v| v.is_a?(Symbol) ? (v == :asc ? 1 : -1) : v } },
                { '$skip' => offset - 1 },
                { '$limit' => 1 },
                { '$project' => { sort_field => 1, '_id' => 1 } }
              ]).first
              
              result
            end
          end
          
          # Build the optimized query
          if boundary
            # Use range query instead of skip
            optimized_query = if sort_direction == 1 || sort_direction == :asc
              # Ascending order: get documents after the boundary
              self.or(
                { sort_field => { '$gt' => boundary[sort_field.to_s] } },
                { sort_field => boundary[sort_field.to_s], :_id => { '$gt' => boundary['_id'] } }
              )
            else
              # Descending order: get documents before the boundary
              self.or(
                { sort_field => { '$lt' => boundary[sort_field.to_s] } },
                { sort_field => boundary[sort_field.to_s], :_id => { '$lt' => boundary['_id'] } }
              )
            end
            
            items = optimized_query.limit(per_page).to_a
          else
            # If no boundary found (we're past the last page), return empty
            items = offset > 0 ? [] : limit(per_page).to_a
          end
          
          pager.replace(items)
          
          # For total_entries, use cached count or estimate for large collections
          if options[:total_entries]
            pager.total_entries = options[:total_entries]
          elsif page <= 5  # Only count for first few pages
            pager.total_entries = Rails.cache.fetch("#{collection.name}_count_#{Digest::MD5.hexdigest(selector.to_json)}", expires_in: 5.minutes) do
              count
            end
          else
            # For later pages, estimate or skip total count
            # This prevents slow counts on large collections
            pager.total_entries = nil
          end
        end
      end
    end
  end
end

# Additional helper for Mongoid criteria
module Mongoid
  module Criteria
    # Add a helper method to check if pagination will be slow
    def pagination_performance_warning(page = 1, per_page = 30)
      offset = (page.to_i - 1) * per_page.to_i
      threshold = ENV.fetch('PAGINATION_OPTIMIZATION_THRESHOLD', 1000).to_i
      
      if offset >= threshold
        Rails.logger.warn "⚠️  Large pagination offset detected: #{offset} (page #{page}). Consider using cursor pagination for better performance."
        
        # Return performance metrics
        {
          warning: true,
          offset: offset,
          estimated_documents_scanned: offset + per_page,
          recommendation: "Use cursor-based pagination or the Event.paginate_by_cursor method",
          alternative_url: "#{request.base_url}#{request.path}?cursor=#{last_cursor}" # if in controller context
        }
      else
        { warning: false, offset: offset }
      end
    end
  end
end

# Log optimization usage
Rails.logger.info "✅ will_paginate MongoDB optimization loaded. Threshold: #{ENV.fetch('PAGINATION_OPTIMIZATION_THRESHOLD', 1000)} documents"