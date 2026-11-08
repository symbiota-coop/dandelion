// Leave column alignment to our templates (text-end), rather than DataTables right-aligning numbers and dates
if (window.DataTable) {
  ['num', 'num-fmt', 'html-num', 'html-num-fmt', 'date'].forEach(function (type) {
    DataTable.type(type, 'className', '')
  })
}

// Generated avatars (.avatar-initials, app.css) take the theme behind them once their stencil has loaded, so they start
// white rather than as a block of colour: those already loaded when this runs, and any that load later, including in
// content loaded later (load doesn't bubble, so this listens in the capture phase)
document.querySelectorAll('img.avatar-initials').forEach(function (img) {
  if (img.complete && img.naturalWidth) img.classList.add('avatar-loaded')
})
document.addEventListener('load', function (e) {
  if (e.target.matches && e.target.matches('img.avatar-initials')) e.target.classList.add('avatar-loaded')
}, true)

$(function () {
  // One tooltip handler for the whole page, so content loaded later needs no setup.
  // Sidebar links have their own, which only show when the sidebar is minified (see _nav.erb)
  new bootstrap.Tooltip(document.body, {
    selector: '[data-bs-toggle="tooltip"]:not(#sidebar *)',
    html: true,
    // The title, or failing that the span after the element. Bootstrap moves title to data-bs-original-title
    title: function (el) {
      return $(el).attr('data-bs-original-title') || $(el).attr('title') || $(el).next('span').html()
    }
  })

  // View as buttons show their labels from 992px, so only smaller screens need their tooltips (_view_as.erb)
  $(document).on('show.bs.tooltip', '.segmented [data-bs-toggle="tooltip"]', function (e) {
    if (window.matchMedia('(min-width: 992px)').matches) e.preventDefault()
  })

  // An account's email copies on click, its tooltip then saying so (accounts/_account.erb)
  $(document).on('click', '.account-email', function (e) {
    e.preventDefault()
    navigator.clipboard.writeText($(this).text().trim())
    const tooltip = bootstrap.Tooltip.getOrCreateInstance(this)
    tooltip.setContent({ '.tooltip-inner': 'Copied!' })
    tooltip.show()
  })
  $(document).on('hidden.bs.tooltip', '.account-email', function () {
    bootstrap.Tooltip.getInstance(this)?.setContent({ '.tooltip-inner': $(this).attr('data-bs-original-title') })
  })

  // A tooltip on a dropdown (_organisationship.erb) hides when its menu opens, and stays hidden while it's open
  $(document).on('show.bs.dropdown', function (e) {
    const tooltipEl = $(e.target).closest('[data-bs-toggle="tooltip"]')[0]
    const tooltip = tooltipEl && bootstrap.Tooltip.getInstance(tooltipEl)
    if (tooltip) tooltip.hide()
  })
  $(document).on('show.bs.tooltip', '[data-bs-toggle="tooltip"]', function (e) {
    if ($(this).find('[data-bs-toggle="dropdown"].show').length) e.preventDefault()
  })

  // The fixed header's height and #content's padding as custom properties, for layouts that fill the rest of
  // the screen (messages.css), updated on resize
  function syncFixedHeaderHeight () {
    document.documentElement.style.setProperty('--fixed-header-height', fixedHeaderHeight() + 'px')

    const content = document.getElementById('content')
    if (content) {
      const contentStyle = getComputedStyle(content)
      document.documentElement.style.setProperty('--content-padding-top', contentStyle.paddingTop)
      document.documentElement.style.setProperty('--content-padding-bottom', contentStyle.paddingBottom)
    }
  }

  syncFixedHeaderHeight()
  $(window).on('resize', syncFixedHeaderHeight)

  // Send data-method="post" links (destroy links among them) as a POST, once confirm.js has confirmed them. Only those:
  // the sanitizer strips data-* attributes from user content, so a link there can't make the viewer POST.
  // This listens in the capture phase, so it runs before any other click handler
  document.addEventListener('click', function (e) {
    if (!e.target.closest) return
    const link = e.target.closest('a[data-method="post"]')
    if (!link) return
    // pagelets.js sends pagelet-trigger links inside a pagelet itself
    if (link.classList.contains('pagelet-trigger') && link.closest('[data-pagelet-url]')) return
    e.preventDefault()
    $('<form>', { method: 'post', action: link.href }).hide().appendTo(document.body)[0].submit()
  }, true)

  // Open a person's profile in #modal, from an avatar or name with data-account-username. Not from inside the modal,
  // which would replace the profile being shown
  $(document).on('click', '[data-account-username]', function () {
    if ($(this).closest('#modal').length) return
    $('#modal .modal-content').load('/u/' + $(this).attr('data-account-username'), function () {
      $('#modal').modal('show')
      hideTooltips()
    })
  })

  // A link with data-open-in-modal opens its page in #modal: the route answers the background request with just the
  // modal's contents (gatherings/_modal_content.erb), and the link's href stays a page of its own to fall back on.
  // Its edit form starts at its first field. Only these: other things #modal shows (an application, a profile) may
  // have a form further down, like a discussion's, which shouldn't take the focus (and bring up a phone's keyboard)
  $(document).on('click', 'a[data-open-in-modal]', function (e) {
    e.preventDefault()
    $('#modal .modal-content').load($(this).attr('href'), function () {
      const $modal = $('#modal')
      const focusFirstField = function () {
        $modal.find('form').find('input:visible, textarea:visible, select:visible').not('[type=hidden]').first().trigger('focus')
      }
      // Already open (a link inside the modal), it won't fire shown.bs.modal again
      if ($modal.hasClass('show')) focusFirstField()
      else $modal.one('shown.bs.modal', focusFirstField).modal('show')
      hideTooltips()
    })
  })

  // Opening the notifications or messages dropdown (_nav_top.erb) marks them as checked: the unread dot (.with-label) goes,
  // and data-check-url records it
  $(document).on('click', '[data-check-url]', function () {
    $(this).removeClass('with-label')
    $.post($(this).attr('data-check-url'))
  })

  // Open the photo a /g/:slug#photo-:id link points to
  if (window.location.hash.startsWith('#photo-')) {
    $('[data-bs-target]').filter(function () { return $(this).attr('data-bs-target') === window.location.hash }).trigger('click')
  }
})
