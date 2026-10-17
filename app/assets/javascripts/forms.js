// Forms: selects, placeholders, date pickers, lookups, slugs and short URLs, colour pickers, autosizing textareas,
// and forms that submit themselves

// Date pickers start the week on Monday. Set outside the ready handler so it's in place before any page's own
// flatpickr calls
flatpickr.l10ns.default.firstDayOfWeek = 1

$(function () {
  // Scrolling over a focused number field changes its value (1 becomes 0 on a trackpad flick), so let go of the field
  // and scroll the page instead
  $(document).on('wheel', 'input[type=number]:focus', function () {
    $(this).blur()
  })

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
      if (!$(input).attr('placeholder')) { $(input).attr('placeholder', $(this).text().trim()) }
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

    $('input.flatpickr-mobile').once('mobile-empty').each(markEmptyDateInput)

    $('textarea[id=comment_body], textarea.autosize').once('autosize').each(function () {
      autosize(this)
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

  // On phones Flatpickr shows a native date input; mark it while empty so app.css can hide Chrome's dd/mm/yyyy mask
  function markEmptyDateInput () {
    $(this).toggleClass('flatpickr-mobile-empty', !this.value)
  }
  $(document).on('input change', 'input.flatpickr-mobile', markEmptyDateInput)

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

  // Submit a .typeWatch field's form once typing has paused for half a second
  $(document).on('input', 'input.typeWatch', function () {
    clearTimeout(this.typeWatchTimer)
    this.typeWatchTimer = setTimeout(() => $(this.form).submit(), 500)
  })

  $(document).on('change', 'input[type=file]', function () {
    if (this.files.length > 0 && this.files[0].size > 10e6) {
      alert('That file is too large, the maximum file size is 10MB. Please resize it before uploading.')
      $(this).val('')
    }
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

  // Coloris opens on any [data-coloris] field, including ones loaded later, so it only needs configuring once
  Coloris({ alpha: false })

  // Mark an input while its autocomplete menu is open, so app.css can square its bottom corners onto the menu
  $(document).on('autocompleteopen autocompleteclose', function (e) {
    $(e.target).toggleClass('autocomplete-open', e.type === 'autocompleteopen')
  })
})
