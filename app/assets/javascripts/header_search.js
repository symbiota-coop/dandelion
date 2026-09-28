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
})
