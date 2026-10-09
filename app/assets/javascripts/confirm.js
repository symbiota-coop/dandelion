// Ask before going ahead with a click on a [data-confirm] element or a destroy link (whose path ends in destroy).
// With a mouse or trackpad, in a popover beside the element: the question (data-confirm, or Are you sure?), Cancel,
// and a button named after the element (data-confirm-label, or its own text or title when short, or Confirm), red for
// destroy links and danger buttons, otherwise primary. Confirming clicks the element again, and that click goes through.
// On touch screens the browser's own confirm() is better: centred, dimming the page, with big buttons.
// These listen on window in the capture phase, so they run before every other handler, including app.js's on document,
// and a click held for confirming reaches none of them
(function () {
  let confirmed = null
  let confirming = null

  function closeConfirm (returnFocus) {
    if (!confirming) return
    const el = confirming
    confirming = null
    const popover = bootstrap.Popover.getInstance(el)
    if (popover) {
      $(el).one('hidden.bs.popover', function () {
        const hidden = bootstrap.Popover.getInstance(el)
        if (hidden) hidden.dispose()
      })
      popover.hide()
    }
    if (returnFocus) el.focus()
  }

  function askToConfirm (el, danger) {
    if (confirming === el) return
    closeConfirm()
    hideTooltips()
    confirming = el

    const ownLabel = $.trim(el.tagName === 'INPUT' ? el.value : el.textContent).replace(/\s+/g, ' ') || el.getAttribute('title') || el.getAttribute('data-bs-original-title')
    const label = el.getAttribute('data-confirm-label') || (ownLabel && ownLabel.length <= 24 ? ownLabel : 'Confirm')
    const confirmButton = $('<button type="button" class="btn btn-sm">').addClass(danger ? 'btn-danger' : 'btn-primary').text(label)
    const body = $('<div>').append(
      $('<p class="mb-2">').text(el.getAttribute('data-confirm') || 'Are you sure?'),
      $('<div class="d-flex flex-wrap justify-content-end gap-2">').append(
        $('<button type="button" class="btn btn-sm btn-secondary">Cancel</button>').on('click', function () { closeConfirm(true) }),
        confirmButton.on('click', function () {
          closeConfirm()
          confirmed = el
          try { el.click() } finally { confirmed = null }
        })
      )
    )

    // One still fading out from the last time is replaced
    const stale = bootstrap.Popover.getInstance(el)
    if (stale) stale.dispose()
    $(el).one('shown.bs.popover', function () { confirmButton.trigger('focus') })
    new bootstrap.Popover(el, { // eslint-disable-line no-new
      content: body[0],
      html: true,
      // Just a body: Bootstrap would otherwise show the element's title as a header
      template: '<div class="popover" role="dialog"><div class="popover-body"></div></div>',
      sanitize: false,
      trigger: 'manual',
      placement: 'top',
      // Inside a modal, so the modal's focus trap lets focus into the popover
      container: el.closest('.modal') || 'body',
      customClass: 'confirm-popover',
      // No arrow, so it sits --space-2xs (4px) from the element, as dropdown menus do
      offset: [0, 4]
    }).show()
  }

  window.addEventListener('click', function (e) {
    if (!e.target.closest) return
    if (confirming && !e.target.closest('.confirm-popover') && !confirming.contains(e.target)) closeConfirm()
    const destroyLink = destroyLinkFor(e.target)
    const confirmable = e.target.closest('[data-confirm]') || destroyLink
    if (!confirmable || confirmable === confirmed) return

    const native = !window.matchMedia('(hover: hover) and (pointer: fine)').matches
    if (native && confirm(confirmable.getAttribute('data-confirm') || 'Are you sure?')) return
    e.preventDefault()
    e.stopPropagation()
    if (!native) askToConfirm(confirmable, destroyLink || $(confirmable).is('.btn-danger, .btn-outline-danger, .text-danger'))
  }, true)

  // Escape cancels. In the capture phase, so inside a modal it doesn't close the modal too
  window.addEventListener('keydown', function (e) {
    if (!confirming || e.key !== 'Escape') return
    e.stopPropagation()
    closeConfirm(true)
  }, true)
})()
