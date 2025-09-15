module PaginationHelper
  extend ActiveSupport::Concern
  
  included do
    helper_method :cursor_pagination_links if respond_to?(:helper_method)
  end
  
  # Use this in controllers for backward-compatible optimized pagination
  def paginate_collection(scope, options = {})
    page = params[:page] || 1
    per_page = options[:per_page] || 30
    
    # Check if cursor parameter exists (for modern API clients)
    if params[:cursor].present?
      result = scope.paginate_by_cursor(
        cursor: params[:cursor],
        limit: per_page,
        sort_field: options[:sort_field] || :start_time,
        sort_direction: options[:sort_direction] || :asc
      )
      
      @pagination_meta = {
        next_cursor: result[:next_cursor],
        has_next: result[:has_next],
        using: 'cursor'
      }
      
      result[:records]
    else
      # Use standard will_paginate (now optimized via our monkey patch)
      records = scope.paginate(page: page, per_page: per_page)
      
      # Add performance warning for large offsets
      if defined?(Rails.logger) && page.to_i > 100
        Rails.logger.warn "📄 Large page number accessed: #{page} for #{scope.collection_name}"
      end
      
      @pagination_meta = {
        current_page: records.current_page,
        total_pages: records.total_pages,
        total_entries: records.total_entries,
        using: 'offset'
      }
      
      records
    end
  end
  
  # Helper for views to generate pagination links
  def cursor_pagination_links(collection, options = {})
    if @pagination_meta && @pagination_meta[:using] == 'cursor'
      content_tag :div, class: 'pagination cursor-pagination' do
        if @pagination_meta[:next_cursor]
          link_to 'Next Page →', url_for(params.permit!.merge(cursor: @pagination_meta[:next_cursor])), 
                  class: 'btn btn-primary'
        else
          content_tag :span, 'No more results', class: 'text-muted'
        end
      end
    else
      # Fall back to standard will_paginate helper
      will_paginate collection, options
    end
  end
  
  # Performance monitoring helper
  def log_pagination_performance
    return unless defined?(@pagination_meta)
    
    if params[:page].to_i > 50
      # Log slow pagination usage for monitoring
      Rails.logger.info({
        event: 'pagination_performance',
        controller: controller_name,
        action: action_name,
        page: params[:page],
        type: @pagination_meta[:using],
        timestamp: Time.current
      }.to_json)
      
      # Set a response header to indicate slow pagination
      response.headers['X-Pagination-Performance'] = 'degraded'
    end
  end
  
  # Migration helper: Provide both pagination styles in API responses
  def render_paginated_json(records, serializer = nil)
    data = serializer ? records.map { |r| serializer.new(r) } : records
    
    response = {
      data: data,
      pagination: @pagination_meta || {}
    }
    
    # For backward compatibility, include will_paginate meta if using offset pagination
    if @pagination_meta && @pagination_meta[:using] == 'offset'
      response[:meta] = {
        current_page: @pagination_meta[:current_page],
        total_pages: @pagination_meta[:total_pages],
        total_entries: @pagination_meta[:total_entries]
      }
    end
    
    # Suggest cursor pagination for clients using high page numbers
    if params[:page].to_i > 10 && @pagination_meta[:using] == 'offset'
      response[:_links] = {
        cursor_pagination: url_for(params.except(:page).merge(cursor: 'start'))
      }
      response[:_performance_hint] = 'Consider using cursor-based pagination for better performance'
    end
    
    render json: response
  end
end