# Extension to override .paginate method to add a limit of x*per_page
# This prevents excessive database queries when paginating large collections

module PaginateWithLimit
  def paginate(options = {})
    per_page = (options[:per_page] || WillPaginate.per_page).to_i
    max_allowed_page = 10
    max_limit = per_page * max_allowed_page

    if is_a?(Mongoid::Criteria)
      requested_page = (options[:page] || 1).to_i
      clamped_page = requested_page.clamp(1, max_allowed_page)

      # Skip expensive count when page_links are disabled
      if options[:page_links] == false
        paginate_without_limit(options.merge(page: clamped_page))
      else
        capped_count = [max_limit, count].min

        max_page = (capped_count.to_f / per_page).ceil
        max_page = 1 if max_page < 1

        final_page = clamped_page.clamp(1, max_page)

        paginate_without_limit(options.merge(total_entries: capped_count, page: final_page))
      end
    else
      paginate_without_limit(options)
    end
  end
end

if defined?(Mongoid::Criteria)
  Mongoid::Criteria.class_eval do
    alias_method :paginate_without_limit, :paginate
    include PaginateWithLimit
  end
end

Array.class_eval do
  alias_method :paginate_without_limit, :paginate
  include PaginateWithLimit
end
