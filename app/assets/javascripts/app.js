function initQuestionsPreview (inputSelector, previewUrl, options) {
  options = options || {}
  const fieldName = inputSelector.replace(/^#\w+?_/, '').replace(/_/g, '-')
  const previewSelector = '#' + fieldName + '-preview'
  const spinnerSelector = '#' + fieldName + '-spinner'
  let timer
  function load () {
    if (!previewUrl) return
    const params = { questions: $(inputSelector).val() }
    if (typeof options.extraParams === 'function') {
      $.extend(params, options.extraParams())
    }
    $(previewSelector).load(previewUrl + '?' + $.param(params), function () {
      $(spinnerSelector).hide()
    })
  }
  $(inputSelector).on('input', function () {
    $(spinnerSelector).show()
    clearTimeout(timer)
    timer = setTimeout(load, 500)
  })
  if (options.refreshOn) {
    $(options.refreshOn).on('change', function () {
      $(spinnerSelector).show()
      load()
    })
  }
  load()
}

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

  const wysiwygEditors = []

  function fixedHeaderHeight () {
    const header = document.getElementById('header')
    return header ? header.getBoundingClientRect().height : 0
  }

  function syncFixedHeaderHeight () {
    const headerHeight = fixedHeaderHeight()
    document.documentElement.style.setProperty('--fixed-header-height', headerHeight + 'px')

    const content = document.getElementById('content')
    if (content) {
      const contentStyle = getComputedStyle(content)
      document.documentElement.style.setProperty('--content-padding-top', contentStyle.paddingTop)
      document.documentElement.style.setProperty('--content-padding-bottom', contentStyle.paddingBottom)
    }

    wysiwygEditors.forEach(function (editor) {
      if (editor.ui && editor.ui.view && editor.ui.view.stickyPanel) {
        editor.ui.view.stickyPanel.viewportTopOffset = headerHeight
      }
    })
  }

  syncFixedHeaderHeight()
  $(window).on('resize', syncFixedHeaderHeight)

  // Grey a select while its chosen option is a disabled placeholder
  function styleSelectElement (select) {
    $(select).css('color', $(select).find('option:selected').is(':disabled') ? 'var(--bs-secondary-color)' : '')
  }

  function ajaxCompleted () {
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

    $('textarea.wysiwyg').once('wysiwyg').each(function () {
      const textarea = this
      ClassicEditor.create(textarea, {
        toolbar: {
          viewportTopOffset: fixedHeaderHeight()
        },
        simpleUpload: {
          uploadUrl: '/upload'
        },
        mediaEmbed: {
          removeProviders: ['facebook', 'twitter', 'instagram', 'googleMaps', 'flickr']
        }
      }).then(editor => {
        textarea.ckeditorInstance = editor
        wysiwygEditors.push(editor)
        syncFixedHeaderHeight()

        textarea.dispatchEvent(new CustomEvent('wysiwyg:ready', {
          bubbles: true,
          detail: { editor: editor }
        }))

        editor.editing.view.document.on('clipboardInput', (evt, data) => {
          const content = data.dataTransfer.getData('text/html')

          if (content) {
            // We have HTML content from the clipboard.
            const domParser = new DOMParser()
            const documentFragment = domParser.parseFromString(content, 'text/html')

            // Traverse the tree and remove color styles.
            const walker = document.createTreeWalker(
              documentFragment,
              NodeFilter.SHOW_ELEMENT,
              {
                acceptNode: function (node) {
                  return (node.style.color || node.style.backgroundColor) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP
                }
              }
            )

            while (walker.nextNode()) {
              walker.currentNode.style.removeProperty('color')
              walker.currentNode.style.removeProperty('background-color')
            }

            // Update the clipboard content.
            data.content = editor.data.processor.toView(documentFragment.body.innerHTML)
          }
        })
      }).catch(error => {
        console.error(error)
      })
    })

    $('.colorpicker').attr('data-coloris', true)

    showTabFromHash()
    navWrappers()
  }

  // Tabs in a .nav-wrapper, and breadcrumbs (.nav-crumbs) on phones, scroll sideways: while there's more
  // to scroll one way, that edge fades and an arrow scrolls it on by most of a width. The active tab is
  // brought into view. Crumbs scroll right to left, where scrollLeft runs from -max to 0
  function navWrappers () {
    $('.nav-wrapper, .nav-crumbs').once('nav-wrapper').each(function () {
      const wrapper = this
      const $scroller = $(wrapper).wrap('<div class="nav-scroller"></div>').parent()
      const arrows = [['start', 'left', 'Scroll left', -1], ['end', 'right', 'Scroll right', 1]].map(function ([edge, icon, label, direction]) {
        return $(`<button type="button" class="nav-scroller-arrow nav-scroller-${edge}" tabindex="-1" aria-label="${label}" style="display: none"><i class="bi bi-chevron-${icon}"></i></button>`)
          .on('click', function () { wrapper.scrollBy({ left: direction * wrapper.clientWidth * 0.75, behavior: window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' }) })
          .appendTo($scroller)
      })
      const update = function () {
        const max = wrapper.scrollWidth - wrapper.clientWidth
        const rtl = getComputedStyle(wrapper).direction === 'rtl'
        const start = wrapper.scrollLeft > (rtl ? -max : 0) + 1
        const end = wrapper.scrollLeft < (rtl ? 0 : max) - 1
        wrapper.classList.toggle('fade-start', start)
        wrapper.classList.toggle('fade-end', end)
        arrows[0].toggle(start)
        arrows[1].toggle(end)
      }
      $(wrapper).on('scroll', update)
      $(window).on('resize', update)
      scrollToActiveTab(wrapper)
      update()
    })
  }

  function scrollToActiveTab (wrapper) {
    const active = $(wrapper).find('.nav-link.active')[0]
    if (!active) return
    if (active.offsetLeft < wrapper.scrollLeft || active.offsetLeft + active.offsetWidth > wrapper.scrollLeft + wrapper.clientWidth) {
      wrapper.scrollLeft = active.offsetLeft - (wrapper.clientWidth - active.offsetWidth) / 2
    }
  }

  $(document).ajaxComplete(function () {
    ajaxCompleted()
  })
  ajaxCompleted()

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

  function showTabFromHash () {
    const hash = window.location.hash
    if (!hash) return
    const $link = $('a[data-bs-toggle="tab"]').filter(function () {
      return this.hash === hash
    })
    if ($link.length && !$link.hasClass('active')) {
      $link.tab('show')
    }
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

  $(document).on('shown.bs.tab', 'a[data-bs-toggle="tab"]', function (e) {
    const wrapper = $(e.target).closest('.nav-wrapper')[0]
    if (wrapper) scrollToActiveTab(wrapper)
    const hash = e.target.hash
    if (hash && window.location.hash !== hash) {
      history.replaceState(null, '', hash)
    }
  })

  $(window).on('hashchange', showTabFromHash)

  let navTabsFormSubmitting = false
  let navTabsFormTouched = false
  $(document).on('submit', 'form:has(.nav-tabs)', function () {
    navTabsFormSubmitting = true
  })
  $(document).on('focusin', 'form:has(.nav-tabs) :input, form:has(.nav-tabs) .ck-editor__editable', function () {
    navTabsFormTouched = true
  })

  // Loader: a bar along the top and a spinner, while an ajax GET has taken more than half a second and while leaving the page
  const $loader = window.noLoader ? $() : $('<div class="loader" style="display: none"><div class="loader-bar"></div><div class="loader-spinner"></div></div>').appendTo('body')
  const $loaderBar = $loader.find('.loader-bar')
  let loaderWidth = 0
  let loaderTrickle = null
  let loaderRequests = 0

  function setLoaderWidth (width) {
    loaderWidth = width
    $loaderBar.css('width', width + '%')
  }

  function startLoader () {
    if (loaderTrickle) return
    $loader.stop(true).css('opacity', '').show()
    setLoaderWidth(10)
    // Creep towards 90% until it's done
    loaderTrickle = setInterval(function () { setLoaderWidth(loaderWidth + (90 - loaderWidth) * 0.1) }, 300)
  }

  function stopLoader () {
    if (!loaderTrickle) return
    clearInterval(loaderTrickle)
    loaderTrickle = null
    setLoaderWidth(100)
    $loader.delay(200).fadeOut(150, function () { setLoaderWidth(0) })
  }

  $(document).on('ajaxSend', function (e, xhr, settings) {
    if (settings.type !== 'GET') return
    loaderRequests++
    const timer = setTimeout(startLoader, 500)
    xhr.always(function () {
      clearTimeout(timer)
      if (--loaderRequests === 0) stopLoader()
    })
  })

  // Downloads fire beforeunload but never leave the page, so pagehide would never hide the loader
  let downloadClicked = false
  $(document).on('click', 'a[href]', function () {
    downloadClicked = this.hasAttribute('download') || /\.(csv|pdf|ics)$/.test(this.pathname)
  })

  $(window).on('beforeunload', function (e) {
    const sidebar = bootstrap.Offcanvas.getInstance('#sidebar')
    if (sidebar) sidebar.hide()

    if (!navTabsFormSubmitting && navTabsFormTouched && $('form:has(.nav-tabs)').length) {
      e.preventDefault()
      e.returnValue = ''
      return ''
    }

    if (downloadClicked) {
      downloadClicked = false
    } else {
      startLoader() // as the user starts navigating away from the page
    }
  })

  // Hide the loader as the user leaves the page, so it doesn't show when they press back
  $(window).on('pagehide', function () {
    clearInterval(loaderTrickle)
    loaderTrickle = null
    $loader.stop(true).hide()
    setLoaderWidth(0)
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
