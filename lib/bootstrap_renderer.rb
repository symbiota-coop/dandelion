module WillPaginate
  module ViewHelpers

    # WillPaginate link renderer for Twitter Bootstrap
    class BootstrapRenderer < WillPaginate::Sinatra::LinkRenderer
      protected

      def page_number(page)
        unless page == current_page
          tag(:li, link(page, page, :class => "page-link", :rel => rel_value(page)), :class => 'page-item')
        else
          tag(:li, link(page, '#', :class => "page-link"), :class => 'page-item active')
        end
      end
      
      def gap
        tag(:li, link('&hellip;', '#', :class => "page-link"), :class => 'page-item disabled')
      end        

      def next_page
        num = @collection.current_page < total_pages && @collection.current_page + 1
        previous_or_next_page(num, @options[:next_label], 'next')
      end

      def previous_page
        num = @collection.current_page > 1 && @collection.current_page - 1
        previous_or_next_page(num, @options[:previous_label], 'previous')
      end

      def previous_or_next_page(page, text, classname)
        if page
          tag(:li, link(text, page, :class => "page-link"), :class => "page-item #{classname}")
        else
          tag(:li, link(text, '#', :class => "page-link"), :class => "page-item disabled #{classname}")
        end
      end

      def html_container(html)
        tag(:ul, html, container_attributes)
      end

    end
  end
end
