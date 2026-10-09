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

  // Grey a select while its chosen option is a disabled placeholder
  function styleSelectElement (select) {
    $(select).css('color', $(select).find('option:selected').is(':disabled') ? 'var(--bs-secondary-color)' : '')
  }

  onContentLoaded(function () {
    $('select').once('select-style').each(function () {
      styleSelectElement(this)
      $(this).removeClass('select-placeholder')
    })

    $('form.add-placeholders label[for]').once('placeholders').each(function () {
      const input = $(this).next().children().first()
      if (!$(input).attr('placeholder')) { $(input).attr('placeholder', $.trim($(this).text())) }
    })

    $('.datepicker').once('flatpickr').flatpickr({
      altInput: true,
      altFormat: 'Y-m-d'
    })
    $('.datetimepicker').once('flatpickr').each(function () {
      var opts = {
        altInput: true,
        altFormat: 'J F Y, H:i',
        enableTime: true,
        time_24hr: true
      }
      var minDate = $(this).data('flatpickr-min-date')
      var maxDate = $(this).data('flatpickr-max-date')
      if (minDate) opts.minDate = minDate
      if (maxDate) opts.maxDate = maxDate
      $(this).flatpickr(opts)

      var linkedEnd = $(this).data('flatpickr-linked-end')
      if (linkedEnd) {
        $(this).on('change', function () {
          var endEl = $(linkedEnd)[0]
          if (endEl && endEl._flatpickr) {
            endEl._flatpickr.set('minDate', this._flatpickr.selectedDates[0])
          }
        })
      }
    })

    $('[id=comment_body]').once('tribute').each(function () {
      const tribute = new Tribute({
        values: function (text, callback) {
          $.get('/network?q=' + encodeURIComponent(text), function (data) {
            callback(data)
          })
        },
        selectTemplate: function (item) {
          return '[@' + item.original.key + '](@' + item.original.value + ')'
        }
      })
      tribute.attach(this)
    })

    $('.tagify').once('tagify').each(function () {
      $(this).html($(this).html().replace(/\[@([\w\s'.-]+)\]\(@(\w+)\)/g, '<a href="/u/$2">$1</a>'))
    })

    $('.linkify').once('linkify').linkify({ target: { url: '_blank' } })

    // Shorten long URLs shown as link text to their origin, e.g. https://example.com/...
    $('.compact-urls').once('compact-urls').find('a').each(function () {
      const text = $(this).text()
      const parts = text.split('/')
      if (/^https?:\/\//.test(text) && text.length > 50 && parts.length > 3) $(this).text(parts[0] + '//' + parts[2] + '/...')
    })

    $('.nl2br').once('nl2br').each(function () {
      $(this).html($(this).html().replace(/(?:\r\n|\r|\n)/g, '<br>'))
    })

    $('.read-more').once('read-more').each(function () {
      const $element = $(this)
      const html = $element.html()
      const brIndex = html.indexOf('<br')

      if (brIndex !== -1) {
        const beforeBr = html.substring(0, brIndex)

        // Keep the full content for the Read more link below
        $element.data('full-content', html)
        $element.html(beforeBr + '<br /><a href="javascript:;" class="read-more-toggle">Read more</a>')
      }
    })

    $('textarea[id=comment_body], textarea.autosize').once('autosize').each(function () {
      autosize(this)
    })

    if (typeof iframely !== 'undefined') {
      $('oembed[url]').once('iframely').each(function () {
        iframely.load(this, $(this).attr('url'))
        if ($(this).parent().is('figure.media')) { $(this).parent().removeClass('media') }
      })
    }

    $('.links-blank').once('links-blank').each(function () {
      $('a[href^=http]', this).attr('target', '_blank')
    })

    $('select.lookup').once('lookup').each(function () {
      $(this).lookup({
        lookup_url: $(this).attr('data-lookup-url'),
        placeholder: $(this).attr('placeholder'),
        id_param: 'id'
      })
    })

    $('input[type=text].slug, div.slugify input[type=text].shorturl').once('slug').each(function () {
      const slug = $(this)
      const start_length = slug.val().length
      const pos = $.inArray(this, $('input', this.form)) - 1
      const title = $($('input', this.form).get(pos))
      slug.focus(function () {
        slug.data('focus', true)
      })
      title.keyup(function () {
        if (start_length == 0 && slug.data('focus') != true) { slug.val(title.val().toLowerCase().replace(/ /g, '-').replace(/[^a-z0-9-]/g, '')) }
      })
    })

    $('.colorpicker').attr('data-coloris', true)
  })

  // Confirm [data-confirm] and destroy links (whose path ends in destroy), then send data-method="post" and destroy links as a POST.
  // This listens in the capture phase, so it runs before any other click handler, and a cancelled click reaches none of them
  document.addEventListener('click', function (e) {
    if (!e.target.closest) return
    const anchor = e.target.closest('a[href]')
    const destroyLink = anchor && /destroy$/.test(new URL(anchor.href, window.location.origin).pathname) ? anchor : null
    const confirmable = e.target.closest('[data-confirm]') || destroyLink
    if (confirmable && !confirm(confirmable.getAttribute('data-confirm') || 'Are you sure?')) {
      e.preventDefault()
      e.stopPropagation()
      return
    }

    const link = destroyLink || e.target.closest('a[data-method="post"]')
    if (!link) return
    // pagelets.js sends pagelet-trigger links inside a pagelet itself
    if (link.classList.contains('pagelet-trigger') && link.closest('[data-pagelet-url]')) return
    e.preventDefault()
    $('<form>', { method: 'post', action: link.href }).hide().appendTo(document.body)[0].submit()
  }, true)

  $(document).on('change', 'select', function () {
    styleSelectElement(this)
  })

  // Before the submitOnChange handler below, so the form submits with the other box already unticked
  $(document).on('change', '.either-or input[type="checkbox"]', function () {
    if (this.checked) $('.either-or input[type="checkbox"]').not(this).prop('checked', false)
  })

  $(document).on('change', 'form.submitOnChange select, form.submitOnChange .flatpickr-input, form.submitOnChange input[type=checkbox], form.submitOnChange input[type=month]', function () {
    $(this.form).submit()
  })

  $(document).on('change', 'input[type=file]', function () {
    if (this.files.length > 0 && this.files[0].size > 10e6) {
      alert('That file is too large, the maximum file size is 10MB. Please resize it before uploading.')
      $(this).val('')
    }
  })

  $(document).on('focusin', '[id=comment_subject], [id=comment_body]', function () {
    $(this.form).find('.comment-options').show()
  })

  $(document).on('click', '[data-account-username]', function () {
    if ($(this).closest('#modal').length) return
    $('#modal .modal-content').load('/u/' + $(this).attr('data-account-username'), function () {
      $('#modal').modal('show')
      hideTooltips()
    })
  })

  // Coloris opens on any [data-coloris] field, including ones loaded later, so it only needs configuring once
  Coloris({ alpha: false })

  // Open the photo a /g/:slug#photo-:id link points to
  if (window.location.hash.startsWith('#photo-')) {
    $('[data-bs-target]').filter(function () { return $(this).attr('data-bs-target') === window.location.hash }).trigger('click')
  }

  // Expand a .read-more for good
  $(document).on('click', '.read-more-toggle', function (e) {
    e.preventDefault()
    const $element = $(this).closest('.read-more')
    $element.html($element.data('full-content'))
  })

  // A saved short URL's link icon copies the whole address. Editing the slug hides it, as it no longer matches
  $(document).on('click', 'input.shorturl + a', function (e) {
    e.preventDefault()
    const $input = $(this).prev()
    navigator.clipboard.writeText($input.prev('.stem').text() + $input.val())
    const tooltip = bootstrap.Tooltip.getOrCreateInstance(this)
    tooltip.setContent({ '.tooltip-inner': 'Copied!' })
    tooltip.show()
  })
  $(document).on('keydown', 'input.shorturl', function () {
    $(this).next('a').hide()
  })

  $(document).on('click', '[data-check-url]', function () {
    $(this).removeClass('with-label')
    $.post($(this).attr('data-check-url'))
  })

  // Submit a .typeWatch field's form once typing has paused for half a second
  $(document).on('input', 'input.typeWatch', function () {
    clearTimeout(this.typeWatchTimer)
    this.typeWatchTimer = setTimeout(() => $(this.form).submit(), 500)
  })

  // Mark an input while its autocomplete menu is open, so app.css can square its bottom corners onto the menu
  $(document).on('autocompleteopen autocompleteclose', function (e) {
    $(e.target).toggleClass('autocomplete-open', e.type === 'autocompleteopen')
  })
})
