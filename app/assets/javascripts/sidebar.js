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
    // Restored by an inline script in application.erb, before first paint
    $('.sidebar .sidebar-scroll').on('scroll', function () {
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
})
