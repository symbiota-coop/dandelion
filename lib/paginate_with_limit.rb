# Extension to override .paginate method to add a limit of x*per_page
# This prevents excessive database queries when paginating large collections

module PaginateWithLimit
  def paginate(options = {})
    per_page = options[:per_page] || WillPaginate.per_page
    max_limit = 10 * per_page.to_i

    # Apply limit before pagination for Mongoid queries
    if respond_to?(:limit) && is_a?(Mongoid::Criteria)
      # Calculate the maximum allowed page based on max_limit
      # This prevents access to excessive page numbers without needing to count
      max_allowed_page = (max_limit.to_f / per_page).ceil
      max_allowed_page = 1 if max_allowed_page < 1

      requested_page = (options[:page] || 1).to_i
      clamped_page = requested_page.clamp(1, max_allowed_page)

      # Skip expensive count when page_links are disabled
      if options[:page_links] == false
        # Just clamp the page and paginate without counting
        paginate_without_limit(options.merge(page: clamped_page))
      else
        # Cap the total_entries at max_limit
        capped_count = [max_limit, count].min

        # Calculate the maximum valid page number based on actual count
        max_page = (capped_count.to_f / per_page).ceil
        max_page = 1 if max_page < 1 # Ensure at least page 1

        # Further clamp to actual data available
        final_page = clamped_page.clamp(1, max_page)

        # Pass total_entries and clamped page to will_paginate
        paginate_without_limit(options.merge(total_entries: capped_count, page: final_page))
      end
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
