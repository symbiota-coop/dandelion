// Shared by the header search and the messages search
function renderSearchAutocompleteItem (ul, item) { // eslint-disable-line no-unused-vars
  const icon = $('<i aria-hidden="true">').addClass('bi').css('margin-right', '0.35em')
  if (typeof item.icon === 'string' && /^bi-[a-z0-9-]+$/.test(item.icon)) {
    icon.addClass(item.icon)
  }
  return $('<li>')
    .append($('<a>').attr('data-value', item.value).append(icon).append($('<span>').text(item.label || '')))
    .appendTo(ul)
}

$(function () {
  const isMobile = /Android|webOS|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent)

  function sidebarMinified () {
    return $('#page-container').hasClass('page-sidebar-minified')
  }

  // Sidebar submenus
  $('.sidebar .nav > .has-sub > a').click(function () {
    if (sidebarMinified()) return
    const target = $(this).next('.sub-menu')
    $('.sidebar .nav > li.has-sub > .sub-menu').not(target).slideUp(250, function () {
      $(this).closest('li').removeClass('expand')
    })
    target.slideToggle(250, function () {
      $(this).closest('li').toggleClass('expand')
    })
  })

  $('.sidebar .nav > .has-sub .sub-menu li.has-sub > a').click(function () {
    if (sidebarMinified()) return
    $(this).next('.sub-menu').slideToggle(250)
  })

  // Mobile sidebar toggle
  $(document).on('click', '[data-click="sidebar-toggled"]', function (e) {
    e.preventDefault()
    $('#page-container').toggleClass('page-sidebar-toggled')
    $(this).toggleClass('active', $('#page-container').hasClass('page-sidebar-toggled'))
  })

  // Sidebar minify
  $('[data-click="sidebar-minify"]').click(function (e) {
    e.preventDefault()
    $('#page-container').toggleClass('page-sidebar-minified')
  })

  // Remember sidebar scroll position
  if (!isMobile) {
    const sidebarScroll = $('.sidebar .sidebar-scroll')
    try {
      const position = localStorage.getItem('sidebarScrollPosition')
      if (position) sidebarScroll.scrollTop(parseInt(position))
    } catch (e) {
      // storage unavailable
    }
    sidebarScroll.on('scroll', function () {
      try {
        localStorage.setItem('sidebarScrollPosition', $(this).scrollTop())
      } catch (e) {
        // storage unavailable
      }
    })
  }

  // Floating submenus when the sidebar is minified
  let floatSubMenuTimeout
  let targetFloatMenu

  function removeFloatSubMenuLater () {
    floatSubMenuTimeout = setTimeout(function () {
      $('.float-sub-menu').remove()
      targetFloatMenu = null
    }, 250)
  }

  function positionFloatSubMenu (menu, top, height) {
    if ($(window).height() - top > height) {
      menu.css({ top: top, bottom: 'auto', overflow: 'initial' })
    } else {
      menu.css({ top: 'auto', bottom: 0, overflow: 'scroll' })
    }
  }

  $(document).on('mouseover', '.float-sub-menu', function () {
    clearTimeout(floatSubMenuTimeout)
  })
  $(document).on('mouseout', '.float-sub-menu', removeFloatSubMenuLater)

  $(document).on('click', '.float-sub-menu li.has-sub > a', function () {
    $(this).next('.sub-menu').slideToggle(250, function () {
      const menu = $('.float-sub-menu')
      positionFloatSubMenu(menu, menu.attr('data-offset-top'), menu.height() + 20)
    })
  })

  $('.sidebar .nav > li.has-sub > a').hover(function () {
    if (!sidebarMinified()) return
    clearTimeout(floatSubMenuTimeout)
    if (targetFloatMenu === this) return
    targetFloatMenu = this

    const subMenu = $(this).closest('li').find('.sub-menu').first()
    const html = subMenu.html()
    if (!html) {
      $('.float-sub-menu').remove()
      targetFloatMenu = null
      return
    }

    const top = $(this).offset().top - $(window).scrollTop()
    let menu = $('.float-sub-menu')
    if (!menu.length) {
      menu = $('<ul class="float-sub-menu"></ul>').appendTo('body')
    }
    menu.html(html).attr('data-offset-top', top).css({ left: 60, right: 'auto' })
    positionFloatSubMenu(menu, top, subMenu.height() + 20)
  }, removeFloatSubMenuLater)

  // Header search bar
  $(document).on('click', '[data-toggle="search-bar"]', function (e) {
    e.preventDefault()
    $('.header-search-bar').addClass('active')
    $('body').append('<a href="javascript:;" data-dismiss="search-bar" id="search-bar-backdrop" class="search-bar-backdrop"></a>')
    $('#search-bar-backdrop').fadeIn(200)
    setTimeout(function () {
      $('#header-search').focus()
    }, 200)
  })

  $(document).on('click', '[data-dismiss="search-bar"]', function (e) {
    e.preventDefault()
    $('.header-search-bar').addClass('inactive')
    setTimeout(function () {
      $('.header-search-bar').removeClass('active inactive')
    }, 200)
    $('#search-bar-backdrop').fadeOut(function () {
      $(this).remove()
    })
  })

  $('#header-search').autocomplete({
    source: '/search',
    minLength: 3,
    open: function () {
      $(this).autocomplete('widget').css({ width: $(this).width() + 'px' })
    },
    search: function () {
      $('.header-search-bar .right-icon').html('<i class="bi bi-spin bi-slash-lg"></i>')
    },
    response: function () {
      $('.header-search-bar .right-icon').html('<i class="bi bi-x-lg"></i>')
    },
    create: function () {
      $(this).data('ui-autocomplete')._renderItem = renderSearchAutocompleteItem
    },
    select: function () {
      $('#header-search').closest('form').submit()
      return false
    }
  }).on('focus', function () {
    $(this).autocomplete('search')
  })
  $('#header-search').autocomplete('widget').addClass('search-bar-autocomplete animated fadeIn')

  $(document).on('click', '.search-bar-autocomplete a', function () {
    $('#header-search').val($(this).attr('data-value'))
    $('#header-search').closest('form').submit()
  })

  // Keep dropdowns open when clicking inside them
  $(document).on('click', '[data-dropdown-close="false"]', function (e) {
    e.stopPropagation()
  })
})
