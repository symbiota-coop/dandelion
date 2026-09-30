$(function () {
  const isMobile = /Android|webOS|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent)

  const desktop = window.matchMedia('(min-width: 768px)')

  // Minified only applies on desktop; on mobile the sidebar is a full-width offcanvas
  function sidebarMinified () {
    return desktop.matches && $('#page-container').hasClass('page-sidebar-minified')
  }

  // Expanded, a group's link slides its submenu open or shut, one open at a time. jQuery's slide rather than
  // Bootstrap's collapse, so clicking again mid-slide reverses it at once (Bootstrap ignores clicks until it's done)
  function slideSubMenu ($menu, open) {
    $menu.data('open', open).siblings('a').attr('aria-expanded', open)
    $menu.stop()[open ? 'slideDown' : 'slideUp'](open ? 350 : 200, function () {
      // Hand back to the collapse/show classes, which the minified sidebar's CSS relies on, dropping the
      // inline sizes an interrupted slide leaves behind
      $menu.toggleClass('show', open).removeAttr('style')
    })
  }

  $('#sidebar').on('click', '.nav > li.has-sub > a', function (e) {
    if (sidebarMinified()) return // a Bootstrap dropdown then
    e.preventDefault()
    const $menu = $(this).siblings('.sub-menu')
    const open = !($menu.data('open') ?? $menu.hasClass('show'))
    if (open) {
      $('#sidebar .nav > li.has-sub > .sub-menu').not($menu).each(function () {
        if ($(this).data('open') ?? $(this).hasClass('show')) slideSubMenu($(this), false)
      })
    }
    slideSubMenu($menu, open)
  })

  // While minified, a group's link toggles a Bootstrap dropdown to its right instead, filled from its submenu
  const $groupLinks = $('#sidebar .nav > li.has-sub > a')
  $groupLinks.closest('li').addClass('dropend').append('<ul class="dropdown-menu dropdown-menu-dark sidebar-dropdown"></ul>')
  // Fixed, so the menu isn't clipped by the sidebar's scroll container
  $groupLinks.attr('data-bs-popper-config', '{"strategy":"fixed"}')

  function syncGroupToggles () {
    $groupLinks.each(function () {
      const dropdown = bootstrap.Dropdown.getInstance(this)
      if (dropdown) dropdown.dispose()
    })
    if (sidebarMinified()) {
      $groupLinks.attr('data-bs-toggle', 'dropdown')
    } else {
      $groupLinks.removeAttr('data-bs-toggle')
    }
  }
  syncGroupToggles()
  desktop.addEventListener('change', syncGroupToggles)

  $('#sidebar').on('show.bs.dropdown', 'li.has-sub', function () {
    const $li = $(this)
    $li.children('.sidebar-dropdown').html($li.children('.sub-menu').html()).find('a').addClass('dropdown-item')
  })

  // On mobile the sidebar is a Bootstrap offcanvas, and the menu button turns into a cross while it's open
  $('#sidebar').on('show.bs.offcanvas hide.bs.offcanvas', function (e) {
    $('.navbar-toggler').toggleClass('active', e.type === 'show')
  })

  // Sidebar minify
  $('[data-click="sidebar-minify"]').click(function (e) {
    e.preventDefault()
    $('#page-container').toggleClass('page-sidebar-minified')
    syncGroupToggles()
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
})
