/* global pusher */

$(function () {
  $.ajaxPrefilter(function (options, originalOptions, jqXHR) {
    const t = '_t=' + Date.now()
    if (options.data) { options.data += '&' + t } else { options.data = t }
  })

  $(document).on('submit', '[data-pagelet-url] form:not(.no-trigger)', function (event) {
    const form = this
    const pagelet = $(form).closest('[data-pagelet-url]')
    pagelet.css('opacity', '0.3')
    if ($(this).hasClass('no-submit')) {
      $('[data-toggle="tooltip"]', pagelet).tooltip('hide')
      pagelet.load(pagelet.attr('data-pagelet-url'), function () {
        pagelet.css('opacity', '1')
      })
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
            $('[data-toggle="tooltip"]', pagelet).tooltip('hide')
            pagelet.load(pagelet.attr('data-pagelet-url'), function () {
              pagelet.css('opacity', '1')
            })
          }
        })
      } else {
        $.post($(form).attr('action'), $(form).serialize(), function () {
          $('[data-toggle="tooltip"]', pagelet).tooltip('hide')
          pagelet.load(pagelet.attr('data-pagelet-url'), function () {
            pagelet.css('opacity', '1')
          })
        })
      }
    }
    return false
  })

  $(document).on('click', '[data-pagelet-url] a.pagelet-trigger', function (event) {
    const a = this
    if ($(a).hasClass('no-trigger')) {
      $(a).removeClass('no-trigger')
      return false
    }
    const pagelet = $(a).closest('[data-pagelet-url]')
    pagelet.css('opacity', '0.3')
    $.get($(a).attr('href'), function () {
      $('[data-toggle="tooltip"]', pagelet).tooltip('hide')
      pagelet.load(pagelet.attr('data-pagelet-url'), function () {
        pagelet.css('opacity', '1')
      })
    })
    return false
  })

  $(document).on('click', '[data-pagelet-url] .pagination a', function (event) {
    const a = this
    const pagelet = $(a).closest('[data-pagelet-url]')
    pagelet.css('opacity', '0.3')
    $('[data-toggle="tooltip"]', pagelet).tooltip('hide')
    pagelet.load($(a).attr('href'), function () {
      pagelet.css('opacity', '1')
      const offset = pagelet.offset()
      if (pagelet.attr('data-pagelet-scroll') != 'false') {
        window.scrollTo(0, offset.top - $('#header').height())
      }
    })
    return false
  })

  $('[data-pagelet-refresh]').each(function () {
    const pagelet = $(this)
    setInterval(function () {
      pagelet.load($(pagelet).attr('data-pagelet-url'))
    }, parseInt($(pagelet).attr('data-pagelet-refresh')) * 1000)
  })

  function pageletPusher () {
    if (typeof (pusher) != 'undefined') {
      $('[data-pusher-channel]:not([data-pusher-channel-registered])').attr('data-pusher-channel-registered', 'true').each(function () {
        const pagelet = $(this)
        const channel = pusher.subscribe(pagelet.attr('data-pusher-channel'))
        channel.bind('updated', function (data) {
          if ($(document).find(pagelet).length == 1) { // only proceed if this pagelet still exists in the DOM, to prevent unnecessary calls to .load()
            $(pagelet).load($(pagelet).attr('data-pagelet-url'))
          }
        })
      })
    }
  }

  function loadEmptyPagelets () {
    $('[data-pagelet-url]').each(function () {
      const pagelet = this
      const placeholder = $(pagelet)[0].hasAttribute('data-with-placeholder')
      if ($(pagelet).html().length == 0 || placeholder) {
        if (placeholder) { $(pagelet).removeAttr('data-with-placeholder') } else { $(pagelet).html('<i class="fa fa-spin fa-circle-o-notch"></i>') }
        $(pagelet).load($(pagelet).attr('data-pagelet-url'))
      }
    })
  }

  $(document).ajaxComplete(function () {
    pageletPusher()
    loadEmptyPagelets()
  })
  pageletPusher()
  loadEmptyPagelets()
})
