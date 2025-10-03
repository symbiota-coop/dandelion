# Extension to override .paginate method to add a limit of x*per_page
# This prevents excessive database queries when paginating large collections

module PaginateWithLimit
  def paginate(options = {})
    per_page = options[:per_page] || WillPaginate.per_page
    max_limit = 10 * per_page.to_i

    # Apply limit before pagination for Mongoid queries
    if respond_to?(:limit) && is_a?(Mongoid::Criteria)
      # Get the actual count (capped at max_limit + 1 to know if there are more)
      limited_collection = limit(max_limit + 1)
      actual_count = limited_collection.count

      # Cap the total_entries at max_limit
      capped_count = [actual_count, max_limit].min

      # Calculate the maximum valid page number
      max_page = (capped_count.to_f / per_page).ceil
      max_page = 1 if max_page < 1 # Ensure at least page 1

      # Clamp the requested page to the valid range
      requested_page = (options[:page] || 1).to_i
      clamped_page = requested_page.clamp(1, max_page)

      # Pass total_entries and clamped page to will_paginate
      paginate_without_limit(options.merge(total_entries: capped_count, page: clamped_page))
    else
      paginate_without_limit(options)
    end
  end
end

# Extend Mongoid::Criteria
if defined?(Mongoid::Criteria)
  Mongoid::Criteria.class_eval do
    alias_method :paginate_without_limit, :paginate
    include PaginateWithLimit
  end
end

# Extend Array
Array.class_eval do
  alias_method :paginate_without_limit, :paginate
  include PaginateWithLimit
end
