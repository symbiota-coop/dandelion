/* global introJs, autosize, google, initQuestionsPreview */

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

  function fieldPresent (value) {
    return value !== undefined && value !== null && value !== ''
  }

  function nestedAttributeList (value) {
    if (!value) return []
    if (Array.isArray(value)) return value
    if (typeof value === 'object') {
      return Object.keys(value).sort(function (a, b) {
        return Number(a) - Number(b)
      }).map(function (key) { return value[key] })
    }
    return []
  }

  function checkboxChecked (value) {
    if (Array.isArray(value)) return value.some(checkboxChecked)
    return value === true || value === '1' || value === 'on' || value === 'true'
  }

  function nestedAttrsPresent (attrs, fields) {
    if (!attrs || checkboxChecked(attrs._destroy)) return false
    return fields.some(function (field) { return fieldPresent(attrs[field]) })
  }

  function setDraftFieldValue ($el, value) {
    $el.each(function () {
      const $field = $(this)
      if ($field.is(':checkbox')) {
        $field.prop('checked', checkboxChecked(value))
        return
      }
      if ($field.attr('type') === 'hidden' && $el.filter(':checkbox').length) return
      if (Array.isArray(value) || !fieldPresent(value) || typeof value === 'object') return
      $field.val(value)
    })
  }

  function nextNestedIndex ($container, rowSelector) {
    let max = -1
    $container.find(rowSelector).each(function () {
      const name = $(this).find('[name]').first().attr('name') || ''
      const match = name.match(/\[(\d+)\]/)
      if (match) max = Math.max(max, Number(match[1]))
    })
    return max + 1
  }

  function initDatetimepickers ($scope) {
    $scope.find('.datetimepicker').not('.flatpickr-registered').addClass('flatpickr-registered').each(function () {
      if (this._flatpickr) return
      $(this).flatpickr({
        altInput: true,
        altFormat: 'J F Y, H:i',
        enableTime: true,
        time_24hr: true
      })
    })
  }

  function addNestedFromTemplate (options) {
    const $container = $(options.containerSelector)
    const template = document.getElementById(options.templateId)
    if (!$container.length || !template) return null

    const index = nextNestedIndex($container, options.rowSelector)
    const clone = $(template.content.cloneNode(true))
    const $row = clone.find(options.rowSelector)
    const attrs = options.attrs || {}

    $row.find('[data-field]').each(function () {
      const field = $(this).data('field')
      $(this).attr('name', options.namePrefix + '[' + index + '][' + field + ']')
      $(this).attr('id', options.idPrefix + index + '_' + field)
      if (Object.prototype.hasOwnProperty.call(attrs, field)) {
        setDraftFieldValue($(this), attrs[field])
      }
    })

    $row.appendTo($container)

    if (typeof $.currencySymbol !== 'undefined') {
      $row.find('.money-symbol').text($.currencySymbol($('#event_currency').val()))
    }
    $row.find('[data-toggle="tooltip"]').tooltip()
    initDatetimepickers($row)
    return $row
  }

  const nestedCollections = {
    ticket_types: {
      key: 'ticket_types_attributes',
      fields: ['name', 'description', 'price', 'quantity', 'price_or_range'],
      templateId: 'ticket_type_template',
      containerSelector: '#ticket_types',
      namePrefix: 'event[ticket_types_attributes]',
      idPrefix: 'event_ticket_types_attributes_',
      rowSelector: '.ticket_type'
    },
    ticket_groups: {
      key: 'ticket_groups_attributes',
      fields: ['name', 'capacity'],
      templateId: 'ticket_group_template',
      containerSelector: '#ticket_groups',
      namePrefix: 'event[ticket_groups_attributes]',
      idPrefix: 'event_ticket_groups_attributes_',
      rowSelector: '.ticket_group',
      afterAdd: function () { $('#ticket_groups_save').show() }
    }
  }

  function addNestedCollection (collection, attrs) {
    if (collection.afterAdd) collection.afterAdd()
    return addNestedFromTemplate($.extend({ attrs: attrs }, collection))
  }

  function updateDraftId (draftId) {
    if (!draftId) return
    config.draftId = draftId
    $('#draft_id').val(draftId)
    try {
      const url = new URL(window.location.href)
      url.searchParams.set('draft_id', draftId)
      if (config.organisationId && !url.searchParams.get('organisation_id')) {
        url.searchParams.set('organisation_id', config.organisationId)
      }
      window.history.replaceState({}, '', url)
    } catch (e) { }
  }

  $('#ticket_types_add').on('click', function () {
    addNestedCollection(nestedCollections.ticket_types)
  })

  $('#ticket_groups_add').on('click', function () {
    addNestedCollection(nestedCollections.ticket_groups)
  })

  // Load draft into form fields (including datetime, wysiwyg, ticket types and groups)
  if (config.draft) {
    const draft = config.draft
    const form = $('#build-event')[0]

    // Set regular form values
    $.each(draft, function (key, value) {
      if (value && typeof value === 'object' && !Array.isArray(value)) return
      const $fields = $(form).find('[name="event[' + key + ']"]')
      if (!$fields.length) return
      setDraftFieldValue($fields, value)
    })

    $.each(nestedCollections, function (_, collection) {
      nestedAttributeList(draft[collection.key]).forEach(function (attrs) {
        if (nestedAttrsPresent(attrs, collection.fields)) addNestedCollection(collection, attrs)
      })
    })

    initDatetimepickers($(form))

    // Set CKEditor content when editors report readiness.
    const hydratedEditors = new WeakSet()
    const applyDraftToEditor = function (editorInstance) {
      if (!editorInstance || hydratedEditors.has(editorInstance) || !editorInstance.sourceElement) return
      const name = editorInstance.sourceElement.getAttribute('name')
      if (!name) return
      const match = name.match(/event\[(.+)\]/)
      const key = match && match[1]
      const html = key && draft[key]
      if (!html) return
      hydratedEditors.add(editorInstance)
      editorInstance.setData(html)
    }
    $(form).find('textarea.wysiwyg').each(function () {
      applyDraftToEditor(this.ckeditorInstance)
    })
    $(form).on('wysiwyg:ready', function (event) {
      const originalEvent = event.originalEvent
      if (!originalEvent || !originalEvent.detail) return
      applyDraftToEditor(originalEvent.detail.editor)
    })
  }

  // Autosave draft + Next buttons on new record
  if (config.newRecord) {
    const saveDraft = function () {
      if ($('#event_name').val().length === 0) return
      $.post('/events/draft', $('#build-event').serializeObject(), function (data) {
        if (data && data.draft_id) updateDraftId(data.draft_id)
      }, 'json')
    }
    const draftInterval = setInterval(saveDraft, 10 * 1000)
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

  // Questions textareas and autosize
  const autosizeFields = [
    ['#event_questions', 8],
    ['#event_feedback_questions', 8],
    ['#event_notes', 2],
    ['#event_terms_and_conditions', 2]
  ]
  autosizeFields.forEach(function (pair) {
    const el = $(pair[0])[0]
    if (el) $(el).attr('rows', pair[1])
    if (el && typeof autosize !== 'undefined') autosize(el)
  })

  // Validate on tab change and keep textareas sized
  $('#event-build-nav a[data-toggle="tab"]').on('show.bs.tab', function (e) {
    setTimeout(function () {
      if (typeof autosize === 'undefined') return
      ;['#event_questions', '#event_feedback_questions', '#event_terms_and_conditions'].forEach(function (sel) {
        const el = $(sel)[0]
        if (el) autosize.update(el)
      })
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

  $('#event-build-nav a[data-toggle="tab"]').on('shown.bs.tab', function () {
    window.scrollTo(0, 0)
  })

  // Evergreen toggle
  $('#event_evergreen').change(function () {
    if ($(this).is(':checked')) {
      $(this).closest('.checkbox').parent().show()
      $('#time-fields, .evergreen-hide').hide()
      $('#event_start_time, #event_end_time, #event_location').removeAttr('required')
      $('#event_location').val('')
        ;['#event_start_time', '#event_end_time'].forEach(function (sel) {
          const el = document.querySelector(sel)
          if (el && el._flatpickr) el._flatpickr.clear()
        })
    } else {
      $('#time-fields, .evergreen-hide').show()
    }
  }).change()

  // Timezone hint (start_time <small> matches gem: sibling of hidden #event_start_time inside the field wrapper)
  if (config.timeZoneSuffix) {
    $('#event_start_time, #event_end_time').siblings('small').text(config.timeZoneSuffix)
  }

  const $evergreen = $('#event_evergreen')
  if (!$evergreen.is(':checked')) {
    const $startSmall = $('#event_start_time').siblings('small')
    $('<a href="javascript:;" class="mt-1">Mark as evergreen/on-demand, with no dates or location</a>')
      .insertAfter($startSmall)
      .on('click', function (e) {
        $(this).hide()
        $evergreen.prop('checked', true).trigger('change')
      })
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
    $('input[name="event[featured]"]').prop('disabled', true)
    $('input[name="event[show_emails]"]').prop('disabled', true)
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
