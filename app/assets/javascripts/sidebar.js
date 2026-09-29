$(function () {
  const isMobile = /Android|webOS|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent)

  function sidebarMinified () {
    return $('#page-container').hasClass('page-sidebar-minified')
  }

  // Sidebar submenus are Bootstrap collapses: one open at a time, and none while minified (they float out on hover instead)
  $('#sidebar').on('show.bs.collapse', '.sub-menu', function (e) {
    if (sidebarMinified()) return e.preventDefault()
    $('#sidebar .sub-menu.show').not(this).collapse('hide')
  })

  // On mobile the sidebar is a Bootstrap offcanvas, and the menu button turns into a cross while it's open
  $('#sidebar').on('show.bs.offcanvas hide.bs.offcanvas', function (e) {
    $('.navbar-toggler').toggleClass('active', e.type === 'show')
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
    menu.html(html).attr('data-offset-top', top).css({ left: $('#sidebar').outerWidth(), right: 'auto' })
    positionFloatSubMenu(menu, top, subMenu.height() + 20)
  }, removeFloatSubMenuLater)
})
