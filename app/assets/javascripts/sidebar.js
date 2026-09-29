$(function () {
  const isMobile = /Android|webOS|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent)

  const desktop = window.matchMedia('(min-width: 768px)')

  // Minified only applies on desktop; on mobile the sidebar is a full-width offcanvas
  function sidebarMinified () {
    return desktop.matches && $('#page-container').hasClass('page-sidebar-minified')
  }

  // Sidebar submenus are Bootstrap collapses, one open at a time
  $('#sidebar').on('show.bs.collapse', '.sub-menu', function () {
    $('#sidebar .sub-menu.show').not(this).collapse('hide')
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
    $groupLinks.attr('data-bs-toggle', sidebarMinified() ? 'dropdown' : 'collapse')
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
