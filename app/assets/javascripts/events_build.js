/* global introJs, ClassicEditor, Tribute, autosize, google */

$(function () {
  // Load config from JSON script tag or window fallback
  const config = (function () {
    try {
      const el = document.getElementById('events-build-config')
      if (el) { return JSON.parse(el.textContent || '{}') }
    } catch (e) { }
    return (window.eventsBuildConfig || {})
  })()

  // Intro tour on new org creation
  if (config.showIntro && $(window).width() > 992) {
    if (typeof introJs !== 'undefined') {
      introJs().setOptions({
        steps: [{
          title: 'Great job!',
          intro: "Now let's create an event under your new organisation."
        }]
      }).start()
    }
  }

  // Load draft into form fields (including datetime and wysiwyg)
  if (config.draft) {
    const draft = config.draft
    const form = $('#build-event')[0]

    // Set regular form values
    $.each(draft, function (key, value) {
      if (value) {
        $(form).find('[name="event[' + key + ']"]').val(value)
      }
    })

    // Set flatpickrs for datetime fields
    $(form).find('input.datetimepicker').each(function () {
      const field = $(this)
      const fieldName = field.attr('name')
      if (fieldName) {
        const match = fieldName.match(/event\[(.+)\]/)
        if (match && draft[match[1]]) {
          field.flatpickr({
            altInput: true,
            altFormat: 'J F Y, H:i',
            enableTime: true,
            time_24hr: true
          })
        }
      }
    })

    // Set CKEditor content
    $(form).find('textarea.wysiwyg').each(function () {
      const field = $(this)
      const fieldName = field.attr('name')
      if (fieldName) {
        const match = fieldName.match(/event\[(.+)\]/)
        if (match && draft[match[1]]) {
          const editorInstance = field.next().find('[contenteditable]')[0].ckeditorInstance
          editorInstance.setData(draft[match[1]])
        }
      }
    })
  }

  // Autosave draft + Next buttons on new record
  if (config.newRecord) {
    const draftInterval = setInterval(function () {
      if ($('#event_name').val().length > 0) {
        $.post('/events/draft', $('#build-event').serializeObject())
      }
    }, 10 * 1000)
    $('#build-event').submit(function () {
      clearInterval(draftInterval)
    })

    $('.tab-pane').each(function () {
      const tabPane = this
      $('<a href="javascript:;" class="next btn btn-primary">Next</a>').appendTo(tabPane)
      $(this).find('a.next').click(function () {
        const nextTab = $(tabPane).next().attr('id')
        $('#event-build-nav a[href="#' + nextTab + '"]').tab('show')

        // Scroll the tab into view
        const navWrapper = $('.nav-wrapper')[0]
        const activeTab = $('#event-build-nav a[href="#' + nextTab + '"]')[0]
        if (navWrapper && activeTab) {
          navWrapper.scrollLeft = activeTab.offsetLeft - (navWrapper.clientWidth / 2) + (activeTab.clientWidth / 2)
        }
      })
    })
    $('.tab-pane:last').find('a.next').remove()
  }

  // Email labels tweaks
  $('label[for$="_email_greeting"], label[for$="_email_body"]').hide()
  $('label[for$="_email_title"]').each(function () {
    $(this).text($(this).text().replace('email subject', 'email'))
  })

  // Questions textareas and autosize
  $('#event_questions').attr('rows', '8')
  $('#event_feedback_questions').attr('rows', '8')
  $('#event_notes').attr('rows', '2')
  if (typeof autosize !== 'undefined') {
    if ($('#event_questions')[0]) autosize($('#event_questions')[0])
    if ($('#event_feedback_questions')[0]) autosize($('#event_feedback_questions')[0])
    if ($('#event_notes')[0]) autosize($('#event_notes')[0])
  }

  // Validate on tab change and keep textareas sized
  $('#event-build-nav a[data-toggle="tab"]').on('show.bs.tab', function (e) {
    setTimeout(function () {
      if (typeof autosize !== 'undefined') {
        if ($('#event_questions')[0]) autosize.update($('#event_questions')[0])
        if ($('#event_feedback_questions')[0]) autosize.update($('#event_feedback_questions')[0])
      }
    }, 0)

    const form = $('#event-build-nav').closest('form')[0]
    if (form.reportValidity()) {
      // continue
    } else {
      e.preventDefault()
      $(window).scrollTop($(form).find(':invalid').first().offset().top - $('#header').height() - 36)
      $(form).find(':invalid').first().focus()
    }
  })

  // Timezone hint
  if (config.timeZoneSuffix) {
    $('#event_start_time').siblings('small').text(config.timeZoneSuffix)
    $('#event_end_time').siblings('small').text(config.timeZoneSuffix)
  }

  // Google Places Autocomplete for location
  if (typeof google !== 'undefined') {
    const autocomplete = new google.maps.places.Autocomplete($('#event_location')[0])
    $('#event_location').keydown(function (e) {
      if (e.which === 13 && $('.pac-container:visible').length) return false
    })
  }

  // Ensure end_time can't be before start_time
  $('#event_start_time').change(function () {
    const startPicker = $('#event_start_time')[0]._flatpickr
    const endPicker = $('#event_end_time')[0]._flatpickr
    if (startPicker && endPicker) {
      endPicker.set('minDate', startPicker.selectedDates[0])
    }
  })

  // Image validation and hints
  $('#event_image').change(function () {
    const fileUpload = this
    const reader = new FileReader()

    reader.readAsDataURL(fileUpload.files[0])
    reader.onload = function (e) {
      const image = new Image()
      image.src = e.target.result
      image.onload = function () {
        const height = this.height
        const width = this.width

        if (width < 992) {
          alert('Please use an image that is at least 992px wide')
          $(fileUpload).val('')
        }
        if (width > 7680) {
          alert('Please use an image that is less than 7680px wide')
          $(fileUpload).val('')
        }
        if (height > width) {
          alert('Please use an image that is more wide than high')
          $(fileUpload).val('')
        }

        if (config.imageRequiredWidth) {
          if (width !== config.imageRequiredWidth) {
            alert('Please use an image that is ' + config.imageRequiredWidth + 'px wide')
            $(fileUpload).val('')
          }
        }
        if (config.imageRequiredHeight) {
          if (height !== config.imageRequiredHeight) {
            alert('Please use an image that is ' + config.imageRequiredHeight + 'px high')
            $(fileUpload).val('')
          }
        }
      }
    }
  })

  if (config.imageRequiredWidth || config.imageRequiredHeight) {
    const $small = $('#event_image').closest('.form-group').find('small')
    if (config.imageRequiredWidth && config.imageRequiredHeight) {
      $small.text('Required image dimensions: ' + config.imageRequiredWidth + 'px x ' + config.imageRequiredHeight + 'px')
    } else if (config.imageRequiredWidth) {
      $small.text('Image must be ' + config.imageRequiredWidth + 'px wide')
    } else if (config.imageRequiredHeight) {
      $small.text('Image must be ' + config.imageRequiredHeight + 'px high')
    }
  }

  // Zoom party toggle
  $('#event_local_group_id').closest('.form-group').css('margin-bottom', '0.25rem')
  $('#do-zoom-party a').click(function () {
    $('#event_zoom_party').click()
  })
  $('#event_zoom_party').change(function () {
    if ($(this).is(':checked')) {
      $('#local-group-select').hide()
      $('#do-zoom-party').hide()
      $('#zoom-party-checkbox').show()
    } else {
      $('#local-group-select').show()
      $('#do-zoom-party').show()
      $('#zoom-party-checkbox').hide()
    }
  }).change()

  // Currency symbol updates
  $('#event_currency').change(function () {
    if (typeof $.currencySymbol !== 'undefined') {
      $('.money-symbol').text($.currencySymbol($(this).val()))
    }
  })

  // Donations UI toggle
  $('#event_suggested_donation').keyup(function () {
    if ($(this).val().length > 0) $('#donation-options').show()
    else $('#donation-options').hide()
  }).keyup()

  // Disable controls for non-admin org members
  if (!config.isOrgAdmin) {
    $('#do-zoom-party').hide()
    $('input[name="event[zoom_party]"]').prop('disabled', true)
    $('input[name="event[monthly_donors_only]"]').prop('disabled', true)
    $('input[name="event[no_discounts]"]').prop('disabled', true)
    $('input[name="event[affiliate_credit_percentage]"]').prop('disabled', true)
    $('input[name="event[featured]"]').prop('disabled', true)
    $('input[name="event[show_emails]"]').prop('disabled', true)
    $('input[name="event[refund_deleted_orders]"]').prop('disabled', true)
  }

  // Revenue share UI if Stripe connected
  if (config.revenueSharingEnabled) {
    $('#event_revenue_sharer_id').change(function () {
      if ($(this).val()) {
        $('#revenue-share').show()
        $('#event_profit_share_to_organiser').val(0).closest('.form-group').hide()
        $('#event_profit_share_to_coordinator, #event_profit_share_to_category_steward, #event_profit_share_to_social_media, #event_profit_share_to_organisation').parent().find('.input-group-text').text('/' + (100 - $('#event_revenue_share_to_revenue_sharer').val()))
      } else {
        $('#revenue-share').hide()
        $('#event_profit_share_to_organiser').closest('.form-group').show()
        $('#event_profit_share_to_coordinator, #event_profit_share_to_category_steward, #event_profit_share_to_social_media, #event_profit_share_to_organisation').parent().find('.input-group-text').text('%')
      }
    }).change()

    $('#event_revenue_share_to_revenue_sharer').change(function () {
      if ($('#event_revenue_sharer_id').val()) {
        $('#event_profit_share_to_coordinator, #event_profit_share_to_category_steward, #event_profit_share_to_social_media, #event_profit_share_to_organisation').parent().find('.input-group-text').text('/' + (100 - $('#event_revenue_share_to_revenue_sharer').val()))
      }
    }).change()

    $('#event_revenue_share_to_revenue_sharer, #event_profit_share_to_organiser, #event_profit_share_to_coordinator, #event_profit_share_to_category_steward, #event_profit_share_to_social_media, #event_profit_share_to_organisation')
      .wrap('<div class="input-group" style="width: 10em"></div>')
      .after('<div class="input-group-append"><span class="input-group-text">%</span></div>')
      .change(function () {
        const sum = $.map($('#event_revenue_share_to_revenue_sharer, #event_profit_share_to_organiser, #event_profit_share_to_coordinator, #event_profit_share_to_category_steward, #event_profit_share_to_social_media'), function (el) {
          return parseInt($(el).val()) || 0
        }).reduce(function (a, b) { return a + b })
        const remaining = 100 - sum
        $('#event_profit_share_to_organisation').val(remaining)
      }).change()
  }

  // Quick theme color circles
  const themeColorInput = $('#build-event').find('input[name="event[theme_color]"]')
  const normalizeHex = (hex) => {
    if (!hex) return ''
    hex = String(hex).replace(/^#/, '').toLowerCase()
    if (hex.length === 3) hex = hex[0] + hex[0] + hex[1] + hex[1] + hex[2] + hex[2]
    return hex
  }
  const updateQuickColorSelection = () => {
    const val = normalizeHex(themeColorInput.val())
    if (!val) {
      $('.quick-color-btn').removeClass('selected')
      return
    }
    $('.quick-color-btn').each(function () {
      $(this).toggleClass('selected', normalizeHex($(this).data('color')) === val)
    })
  }
  const updateThemeCSS = () => {
    const hex = normalizeHex(themeColorInput.val())
    const $oldLink = $('link[href^="/theme.css"]')
    if (hex) {
      const href = '/theme.css?theme_color=' + encodeURIComponent('#' + hex)
      if ($oldLink.length && $oldLink.attr('href') === href) return
      const $newLink = $('<link>', { rel: 'stylesheet', href: href })
      $newLink.on('load', function () { $oldLink.remove() })
      $newLink.appendTo('head')
    } else {
      $oldLink.remove()
    }
  }
  updateQuickColorSelection()
  themeColorInput.on('change', function () {
    updateQuickColorSelection()
    updateThemeCSS()
  })
  $('.quick-color-btn').click(function () {
    const color = $(this).data('color')
    if (themeColorInput.length && color) {
      themeColorInput.val(color)
      if (themeColorInput.data('colorpicker')) {
        themeColorInput.colorpicker('setValue', color)
      }
      themeColorInput.trigger('change')
    }
  })

  // Prevent double-submit
  $('#build-event').submit(function () {
    $(this).find('button[type=submit]').prop('disabled', true)
  })

  // Live preview for questions
  if (config.eventId) {
    initQuestionsPreview('#event_questions', '/events/' + config.eventId + '/questions')
    initQuestionsPreview('#event_feedback_questions', '/events/' + config.eventId + '/feedback_questions')
  }
})
