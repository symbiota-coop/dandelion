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
  // The search bar is a Bootstrap offcanvas: focus the field once it has slid in
  $('#header-search-bar').on('shown.bs.offcanvas', function () {
    $('#header-search').trigger('focus')
  }).on('hide.bs.offcanvas', function () {
    $('#header-search').autocomplete('close')
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
  $('#header-search').autocomplete('widget').addClass('search-bar-autocomplete')

  $(document).on('click', '.search-bar-autocomplete a', function () {
    $('#header-search').val($(this).attr('data-value'))
    $('#header-search').closest('form').submit()
  })
})
