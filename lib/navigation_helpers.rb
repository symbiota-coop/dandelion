module NavigationHelpers
  def dropdown_nav(items,
                   container_class: 'btn-group',
                   container_id: '',
                   button_class: 'btn btn-outline-primary dropdown-toggle',
                   button_id: '',
                   button_text: '',
                   menu_class: 'dropdown-menu',
                   item_class: 'dropdown-item',
                   item_active_class: 'active')

    s = ''
    s << %(<div class="#{container_class}" id="#{container_id}">)
    s << %(<button class="#{button_class}" type="button" id="#{button_id}" data-bs-toggle="dropdown" data-mobile-modal="#{mobile_modal_title(button_text)}"><span class="dropdown-nav-name">#{button_text}</span> <i class="bi bi-caret-down-fill"></i></button>)
    s << %(<div class="#{menu_class}">)
    items.each do |item|
      name, path, attrs = item
      s << if name.nil?
             %(<div class="dropdown-divider"></div>)
           elsif path.nil?
             %(<h6 class="dropdown-header">#{name}</h6>)
           else
             attr_str = ''
             if attrs.is_a?(Hash)
               attrs.each do |k, v|
                 attr_str << %( #{k}="#{ERB::Util.html_escape(v)}")
               end
             end
             %(<a class="#{item_class} #{item_active_class if request.path == path}" href="#{path}"#{attr_str}>#{name}</a>)
           end
    end
    s << '</div>'
    s << '</div>'
    s.html_safe
  end

  def ul_nav(items,
             prefix: '',
             ul_class: 'navbar-nav',
             li_class: 'nav-item',
             li_active_class: '',
             a_class: 'nav-link',
             a_active_class: 'active',
             ul_id: '',
             subnav_li_class: 'nav-item dropdown',
             subnav_data_toggle: 'dropdown',
             subnav_a_class: 'nav-link dropdown-toggle',
             subnav_href: 'javascript:;',
             subnav_caret: '<i class="bi bi-chevron-down caret"></i>',
             subnav_ul_class: 'dropdown-menu',
             subnav_ul_id: '',
             subnav_li2_class: 'nav-item',
             subnav_a2_class: 'dropdown-item',
             generate_subnav_href_and_ul: false)
    s = ''
    s << %(<ul class="#{ul_class}" id="#{ul_id}">)
    items.each do |name, path|
      if path.is_a? Array
        if generate_subnav_href_and_ul
          uuid = SecureRandom.uuid
          subnav_href = "##{uuid}"
          subnav_ul_id = uuid
        end
        s << %(<li class="#{subnav_li_class}">)
        s << %(<a data-bs-toggle="#{subnav_data_toggle}" data-mobile-modal="#{mobile_modal_title(name)}" class="#{subnav_a_class}" href="#{subnav_href}">#{name}#{subnav_caret}</a>)
        s << ul_nav(path, prefix: prefix, ul_class: subnav_ul_class, ul_id: subnav_ul_id, li_class: subnav_li2_class,
                          li_active_class: li_active_class, a_class: subnav_a2_class, a_active_class: a_active_class)
        s << %(</li>)
      elsif path.nil?
        s << %(<li class="dropdown-divider"></li>)
      else
        path = "#{prefix}#{path}" if prefix
        s << %(<li)
        s << %( class="#{li_class} #{li_active_class if request.path == path}" )
        s << %(>)
        s << %(<a class="#{a_active_class if request.path == path} #{a_class}" href="#{path}">#{name}</a>)
        s << %(</li>)
      end
    end
    s << %(</ul>)
    s.html_safe
  end

  def nav_crumbs_scroll_script
    '<script>(el => { el.scrollLeft = el.scrollWidth })(document.currentScript.previousElementSibling)</script>'.html_safe
  end

  # The title of the bottom sheet a dropdown opens as on mobile: the toggle's text without its HTML
  def mobile_modal_title(html)
    ERB::Util.html_escape(CGI.unescapeHTML(Sanitize.fragment(html)).squish)
  end
end
