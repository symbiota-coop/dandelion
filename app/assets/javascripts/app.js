// Leave column alignment to our templates (text-end), rather than DataTables right-aligning numbers and dates
if (window.DataTable) {
  ['num', 'num-fmt', 'html-num', 'html-num-fmt', 'date'].forEach(function (type) {
    DataTable.type(type, 'className', '')
  })
}

$(function () {
  // One tooltip handler for the whole page, so content loaded later needs no setup.
  // Sidebar links have their own, which only show when the sidebar is minified (see _nav.erb)
  new bootstrap.Tooltip(document.body, { // eslint-disable-line no-new
    selector: '[data-bs-toggle="tooltip"]:not(#sidebar *)',
    html: true,
    // The title, or failing that the span after the element. Bootstrap moves title to data-bs-original-title
    title: function (el) {
      return $(el).attr('data-bs-original-title') || $(el).attr('title') || $(el).next('span').html()
    }
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

  // Send data-method="post" and destroy links as a POST, once confirm.js has confirmed them.
  // This listens in the capture phase, so it runs before any other click handler
  document.addEventListener('click', function (e) {
    if (!e.target.closest) return
    const link = destroyLinkFor(e.target) || e.target.closest('a[data-method="post"]')
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
