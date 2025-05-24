$(function () {
  $.ajaxPrefilter(function (options) {
    const t = '_t=' + Date.now()
    if (options.data) { options.data += '&' + t } else { options.data = t }
  })

  function postLoad (pagelet) {
    if (!pagelet.is('[data-pagelet-no-opacity-change]')) {
      pagelet.css('opacity', '1')
    }
    $('.tooltip').remove()
    $('[data-pagelet-refresh-paused]').removeAttr('data-pagelet-refresh-paused')
    if (pagelet.attr('data-pagelet-also')) {
      let alsoRefresh = $('[data-pagelet-url="' + pagelet.attr('data-pagelet-also') + '"]')
      alsoRefresh.load(alsoRefresh.attr('data-pagelet-url'))
    }
  }

  $(document).on('submit', '[data-pagelet-url] form:not(.no-trigger)', function () {
    const form = this
    const pagelet = $(form).closest('[data-pagelet-url]')
    if (!pagelet.is('[data-pagelet-no-opacity-change]')) {
      pagelet.css('opacity', '0.3')
    }
    if ($(this).hasClass('no-submit')) {
      pagelet.load(pagelet.attr('data-pagelet-url'), function () { postLoad(pagelet) })
    } else {
      if ($(form).find('input[type=file]').length > 0 && $(form).find('input[type=file]').map(function () {
        return $(this).val()
      }).toArray().join('') != '') {
        const formData = new FormData(form)
        $.ajax({
          type: 'POST',
          url: $(form).attr('action'),
          data: formData,
          success: function () {
            pagelet.load(pagelet.attr('data-pagelet-url'), function () { postLoad(pagelet) })
          }
        })
      } else {
        $.post($(form).attr('action'), $(form).serialize(), function () {
          pagelet.load(pagelet.attr('data-pagelet-url'), function () { postLoad(pagelet) })
        })
      }
    }
    return false
  })

  $(document).on('click', '[data-pagelet-url] a.pagelet-trigger', function () {
    const a = this
    if ($(a).hasClass('no-trigger')) {
      $(a).removeClass('no-trigger')
      return false
    }
    const pagelet = $(a).closest('[data-pagelet-url]')
    if (!pagelet.is('[data-pagelet-no-opacity-change]')) {
      pagelet.css('opacity', '0.3')
    }
    $.get($(a).attr('href'), function () {
      pagelet.load(pagelet.attr('data-pagelet-url'), function () { postLoad(pagelet) })
    })
    return false
  })

  $(document).on('click', '[data-pagelet-url] .pagination a', function () {
    const a = this
    const pagelet = $(a).closest('[data-pagelet-url]')
    if (!pagelet.is('[data-pagelet-no-opacity-change]')) {
      pagelet.css('opacity', '0.3')
    }
    pagelet.load($(a).attr('href'), function () {
      if (!pagelet.is('[data-pagelet-no-opacity-change]')) {
        pagelet.css('opacity', '1')
      }
      $('.tooltip').remove()
      const offset = pagelet.offset()
      if (pagelet.attr('data-pagelet-scroll') != 'false') {
        window.scrollTo(0, offset.top - $('#header').height() - 20)
      }
    })
    return false
  })


  function pageletRefresh () {
    $('[data-pagelet-refresh]:not([data-pagelet-refresh-registered])').attr('data-pagelet-refresh-registered', 'true').each(function () {
      const rawPagelet = this
      const pagelet = $(this)
      function applyRefreshPause () {
        $("a[href='javascript:;']", pagelet).click(function () {
          pagelet.attr('data-pagelet-refresh-paused', 'true')
        });
      }
      function refreshProcess () {
        if (!$(rawPagelet)[0].hasAttribute('data-pagelet-refresh-paused')) {
          pagelet.load(pagelet.attr('data-pagelet-url'), function () {
            applyRefreshPause()
            if (pagelet.attr('data-pagelet-also')) {
              let alsoRefresh = $('[data-pagelet-url="' + pagelet.attr('data-pagelet-also') + '"]')
              alsoRefresh.load(alsoRefresh.attr('data-pagelet-url'))
            }
          })
        }
      }
      applyRefreshPause()
      setInterval(refreshProcess, parseInt(pagelet.attr('data-pagelet-refresh')) * 1000)
    })
  }

  function loadEmptyPagelets () {
    $('[data-pagelet-url]').each(function () {
      const rawPagelet = this
      const placeholder = $(rawPagelet)[0].hasAttribute('data-with-placeholder')
      if ($(rawPagelet).html().length == 0 || placeholder) {
        if (placeholder) { $(rawPagelet).removeAttr('data-with-placeholder') } else { $(rawPagelet).html('<i class="pagelet-loading bi bi-spin bi-arrow-repeat"></i>') }
        $(rawPagelet).load($(rawPagelet).attr('data-pagelet-url'))
      }
    })
  }

  $(document).ajaxComplete(function () {
    pageletRefresh()
    loadEmptyPagelets()
  })
  pageletRefresh()
  loadEmptyPagelets()
})
