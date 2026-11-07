# Caps Mongoid criteria's .paginate at 10 pages, so a high ?page= can't make the database skip through a large
# collection. Only criteria: will_paginate defines Array#paginate on Array itself, which an included module can't override
module PaginateWithLimit
  def paginate(options = {})
    per_page = (options[:per_page] || WillPaginate.per_page).to_i
    max_allowed_page = 10
    max_limit = per_page * max_allowed_page

    requested_page = (options[:page] || 1).to_i
    clamped_page = requested_page.clamp(1, max_allowed_page)

    # Skip expensive count when page_links are disabled
    if options[:page_links] == false
      paginate_without_limit(options.merge(page: clamped_page))
    else
      total = count
      capped_count = [max_limit, total].min

      max_page = (capped_count.to_f / per_page).ceil
      max_page = 1 if max_page < 1

      final_page = clamped_page.clamp(1, max_page)

      # total_entries is capped so pages stop at max_allowed_page; uncapped_total_entries keeps the real count,
      # which was counted anyway, for pagination_details to show
      paginate_without_limit(options.merge(total_entries: capped_count, page: final_page)).tap do |collection|
        collection.define_singleton_method(:uncapped_total_entries) { total }
      end
    end
  end
end

Mongoid::Criteria.class_eval do
  alias_method :paginate_without_limit, :paginate
  include PaginateWithLimit
end
