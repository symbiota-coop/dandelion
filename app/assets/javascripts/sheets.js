// Sheets: on phones, dropdowns marked data-mobile-modal and the event stats row open in #nav-dropdown-sheet
// (layouts/application.erb), an offcanvas along the bottom of the screen
$(function () {
  $(document).on('show.bs.dropdown', '[data-mobile-modal]', function (e) {
    const $toggle = $(this)
    const title = $toggle.attr('data-mobile-modal')
    if (!title || $(window).width() >= 768) return

    e.preventDefault()

    const $source = $toggle.siblings('[data-pagelet-url]')
    let $list = $source.children('.list-group').clone()
    // Plain dropdown menus (dropdown_nav, ul_nav) become a list group of their items and headers
    if (!$source.length) {
      $list = $('<div class="list-group list-group-flush"></div>')
      $toggle.siblings('.dropdown-menu').find('.dropdown-item, .dropdown-header, .dropdown-divider').each(function () {
        if ($(this).hasClass('dropdown-divider')) return $list.append('<hr class="my-1">')
        const $item = $(this).clone(true)
        if (!$item.hasClass('dropdown-header')) $item.removeClass('dropdown-item').addClass('list-group-item list-group-item-action')
        $list.append($item)
      })
    }
    const $body = showSheet(title)
    if ($list.length) {
      $body.append($list)
    } else {
      $body.html('<div class="text-center p-4"><i class="bi bi-spin bi-slash-lg"></i></div>')
        .load($source.attr('data-pagelet-url'))
    }
  })

  // The event stats row as a list of its columns, since the table is far wider than a phone
  $(document).on('click', '[data-stats-sheet]', function () {
    const $table = $($(this).attr('data-stats-sheet'))
    const $cells = $table.find('tbody tr').first().children()
    const $list = $('<div class="list-group list-group-flush"></div>')
    $table.find('thead tr').first().children().each(function (i) {
      const label = $(this).text().trim()
      const $cell = $cells.eq(i)
      if (i === 0 || !label || $(this).css('display') === 'none') return
      const $value = $('<span class="text-end"></span>').append($cell.contents().clone())
      // Drop avatars along with their now-empty links, then any line breaks that led into the text
      $value.find('img').each(function () {
        const $parent = $(this).parent()
        $(this).remove()
        if ($parent.is('a') && !$parent.children().length && !$parent.text().trim()) $parent.remove()
      })
      let first
      while ((first = $value[0].firstChild) && (first.nodeName === 'BR' || (first.nodeType === 3 && !first.textContent.trim()))) {
        first.remove()
      }
      $list.append($('<div class="list-group-item d-flex justify-content-between align-items-start gap-3"></div>')
        .append($('<span class="text-body-secondary"></span>').text(label), $value))
    })
    showSheet('Stats').append($list)
  })

  function showSheet (title) {
    const $sheet = $('#nav-dropdown-sheet')
    $sheet.find('.offcanvas-title').text(title)
    bootstrap.Offcanvas.getOrCreateInstance($sheet[0]).show()
    return $sheet.find('.offcanvas-body').empty()
  }
})
