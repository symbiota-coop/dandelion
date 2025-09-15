# Example of how to update your events controller with optimized pagination
# This shows different approaches you can use

Dandelion::App.controller do
  # Include the pagination helper
  include PaginationHelper
  
  # OPTION 1: Minimal change - just keep using paginate() as before
  # The monkey patch will automatically optimize it for large offsets
  get '/events/example1' do
    @events = Event.live.public.browsable.future
    
    # This will automatically use the optimized version for large page numbers
    @events = @events.paginate(page: params[:page], per_page: 30)
    
    erb :'events/index'
  end
  
  # OPTION 2: Use the new paginate_collection helper for automatic optimization
  get '/events/example2' do
    @events = Event.live.public.browsable.future
    
    # This helper handles both cursor and offset pagination
    @events = paginate_collection(@events, 
      per_page: 30,
      sort_field: :start_time,
      sort_direction: :asc
    )
    
    # Log performance for monitoring
    log_pagination_performance
    
    erb :'events/index'
  end
  
  # OPTION 3: Explicitly use cursor pagination for APIs
  get '/api/events', provides: [:json] do
    events = Event.live.public.browsable.future
    
    if params[:cursor]
      # Modern clients can use cursor pagination
      result = events.paginate_by_cursor(
        cursor: params[:cursor],
        limit: params[:per_page] || 30,
        sort_field: :start_time
      )
      
      json({
        events: result[:records],
        next_cursor: result[:next_cursor],
        has_next: result[:has_next]
      })
    else
      # Backward compatibility with page numbers
      @events = events.paginate(page: params[:page], per_page: 30)
      
      # Warn API clients about performance for high page numbers
      if params[:page].to_i > 50
        response.headers['X-Pagination-Warning'] = 'Consider using cursor pagination for better performance'
      end
      
      json({
        events: @events,
        page: @events.current_page,
        total_pages: @events.total_pages,
        total_entries: @events.total_entries
      })
    end
  end
  
  # OPTION 4: Hybrid approach with performance fallback
  get '/events/smart' do
    @events = Event.live.public.browsable.future
    page = params[:page].to_i
    
    if page > 100
      # For very high page numbers, force cursor pagination
      # Generate a cursor for the target page
      skip_to = (page - 1) * 30
      boundary = @events.skip(skip_to - 1).first
      
      if boundary
        cursor = boundary.to_cursor(:start_time)
        redirect "/events/smart?cursor=#{cursor}"
      else
        @events = []
      end
    else
      # For reasonable page numbers, use optimized paginate
      @events = @events.paginate(page: page, per_page: 30)
    end
    
    erb :'events/index'
  end
  
  # OPTION 5: Provide both interfaces in parallel
  get '/events/modern' do
    @events = Event.live.public.browsable.future
    
    # Let the helper decide based on parameters
    @events = paginate_collection(@events, per_page: 30)
    
    respond_to do |format|
      format.html { erb :'events/index' }
      format.json { render_paginated_json(@events) }
    end
  end
end

# Quick migration guide:
# 
# 1. NO CHANGES NEEDED - The monkey patch works automatically
#    Your existing code like this will be optimized:
#    @events = Event.where(...).paginate(page: params[:page], per_page: 30)
#
# 2. To add cursor pagination support (better for APIs):
#    - Add `include PaginationHelper` to your controller
#    - Use `paginate_collection` instead of `paginate`
#    - Your API clients can now use ?cursor=xxx instead of ?page=xxx
#
# 3. Monitor performance:
#    - Check logs for "Large pagination offset detected" warnings
#    - Set PAGINATION_OPTIMIZATION_THRESHOLD env var (default 1000)
#
# 4. For best performance on frequently accessed pages:
#    - Pages 1-10: Regular pagination is fine
#    - Pages 10-100: Automatically optimized
#    - Pages 100+: Consider redirecting to cursor pagination