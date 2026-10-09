// Resolves a CSS colour expression such as 'var(--theme-500)' to a plain colour, for canvas, charts and maps,
// which can't read custom properties themselves. Call it once the page has loaded
// Returns rgb() or rgba(), as some libraries can't parse oklch() or color()
function cssColor (value) {
  const probe = document.createElement('span')
  probe.style.color = value
  document.body.appendChild(probe)
  const color = getComputedStyle(probe).color
  probe.remove()
  const context = (cssColor.canvas ||= document.createElement('canvas')).getContext('2d', { willReadFrequently: true })
  context.clearRect(0, 0, 1, 1)
  context.fillStyle = color
  context.fillRect(0, 0, 1, 1)
  const [r, g, b, a] = context.getImageData(0, 0, 1, 1).data
  return a === 255 ? `rgb(${r}, ${g}, ${b})` : `rgba(${r}, ${g}, ${b}, ${Math.round(a / 2.55) / 100})`
}

// The link a click was on, if its path ends in destroy. confirm.js asks before following these, and app.js sends them as a POST
function destroyLinkFor (target) {
  const anchor = target.closest('a[href]')
  return anchor && /destroy$/.test(new URL(anchor.href, window.location.origin).pathname) ? anchor : null
}

// Hide every tooltip, including any whose element a pagelet has just replaced
function hideTooltips () {
  document.querySelectorAll('[data-bs-toggle="tooltip"]').forEach(function (el) {
    const tooltip = bootstrap.Tooltip.getInstance(el)
    if (tooltip) tooltip.hide()
  })
  $('.tooltip').remove()
}

// Loads a live preview of a questions field (#x_questions shows in #questions-preview, with #questions-spinner while loading),
// half a second after typing stops and whenever options.refreshOn changes. options.extraParams adds to the query
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

// Runs fn now and again after every ajax request, to set up content loaded later (see $.fn.once below).
// Call it once the page has loaded
function onContentLoaded (fn) {
  fn()
  $(document).on('ajaxComplete', function () { fn() })
}

// The height of the fixed #header, which sticky elements sit below
function fixedHeaderHeight () {
  const header = document.getElementById('header')
  return header ? header.getBoundingClientRect().height : 0
}

// The elements not yet set up under this key, now marked as set up, so code that runs after every ajax request
// sets each element up once: $('.linkify').once('linkify').linkify(). The mark is a class (once-linkify) rather than
// a data attribute because flatpickr copies classes, not data attributes, onto the alt input it adds
$.fn.once = function (key) {
  return this.not('.once-' + key).addClass('once-' + key)
}

$.currencySymbol = function (currency) {
  try {
    const parts = new Intl.NumberFormat('en', { style: 'currency', currency: currency })
      .formatToParts();
    const symbol = parts.find(part => part.type === 'currency');
    const symbolValue = symbol ? symbol.value : currency;

    // If symbol is compound (>1 char) and ends with $, return original currency code
    return (symbolValue.length > 1 && symbolValue.endsWith('$')) ? currency : symbolValue;
  } catch (e) {
    return currency;
  }
}

// The reverse of $.param: turns a query string into an object, so a=1&a=2 gives { a: ['1', '2'] },
// a[]=1&a[]=2 gives { a: ['1', '2'] }, a[0]=1 gives { a: ['1'] } and a[b][c]=1 gives { a: { b: { c: '1' } } }
$.deparam = function (query) {
  const obj = {}

  new URLSearchParams(query).forEach(function (value, name) {
    const match = name.match(/^([^[\]]+)((?:\[[^[\]]*\])+)$/)
    const keys = match ? [match[1]].concat(match[2].slice(1, -1).split('][')) : [name]
    if (keys.some(key => ['__proto__', 'constructor', 'prototype'].includes(key))) return

    if (keys.length === 1) {
      if (Array.isArray(obj[name])) {
        obj[name].push(value)
      } else if (Object.hasOwn(obj, name)) {
        obj[name] = [obj[name], value]
      } else {
        obj[name] = value
      }
      return
    }

    let current = obj
    keys.forEach(function (key, i) {
      if (key === '' && Array.isArray(current)) key = current.length
      if (i === keys.length - 1) {
        current[key] = value
      } else {
        // The next key decides what this level holds: [] or [0] make an array, [b] an object
        if (typeof current[key] !== 'object') current[key] = isNaN(keys[i + 1]) ? {} : []
        current = current[key]
      }
    })
  })

  return obj
}

$.fn.serializeObject = function () {
  const o = {};
  const a = this.serializeArray();

  // Helper to set nested value
  function setNestedValue (obj, path, value) {
    const keys = path.replace(/\]/g, '').split('[')
    let current = obj
    for (let i = 0; i < keys.length - 1; i++) {
      const key = keys[i]
      if (!(key in current)) {
        current[key] = {}
      }
      current = current[key]
    }
    const lastKey = keys[keys.length - 1]
    // Handle multiple values (checkboxes, multi-select)
    if (lastKey in current) {
      if (!Array.isArray(current[lastKey])) {
        current[lastKey] = [current[lastKey]]
      }
      current[lastKey].push(value)
    } else {
      current[lastKey] = value
    }
  }

  // Handle regular form fields
  $.each(a, function () {
    setNestedValue(o, this.name, this.value || '')
  });

  // Handle CKEditor 5 fields (overwrite any existing value from hidden textarea)
  this.find('textarea.wysiwyg').each(function () {
    const editorInstance = this.ckeditorInstance
    if (!editorInstance) return
    const fieldName = this.getAttribute('name') || (editorInstance.sourceElement && editorInstance.sourceElement.getAttribute('name'))
    if (!fieldName) return
    const data = editorInstance.getData()
    // Parse the field name and set directly (overwriting, not appending)
    const keys = fieldName.replace(/\]/g, '').split('[')
    let current = o
    for (let i = 0; i < keys.length - 1; i++) {
      const key = keys[i]
      if (!(key in current)) {
        current[key] = {}
      }
      current = current[key]
    }
    current[keys[keys.length - 1]] = data
  })

  return o;
};


(function ($) {
  $.fn.lookup = function (options) {
    return this.each(function () {
      var $el = $(this)
      var initialId = $el.find('option:selected').val()

      // If there's an initial value, fetch its display text from the server (like v3 initSelection)
      if (initialId && initialId !== '') {
        var $option = $el.find('option:selected')
        $option.text('Loading...')
        var data = {}
        data[(options.id_param || $el.attr('name'))] = initialId
        data.rtype = options.rtype
        $.getJSON(options.lookup_url, data, function (response) {
          var result = response.results.filter(function (r) {
            return r.id == initialId
          })[0]
          $option.text(result ? result.text : initialId)
          initSelect2()
        }).fail(function () {
          $option.text(initialId) // Show ID as fallback
          initSelect2()
        })
      } else {
        initSelect2()
      }

      function initSelect2 () {
        $el.select2({
          theme: 'bootstrap-5',
          placeholder: options.placeholder,
          allowClear: true,
          minimumInputLength: 1,
          ajax: {
            url: options.lookup_url,
            dataType: 'json',
            delay: 250,
            data: function (params) {
              return {
                q: params.term,
                rtype: options.rtype
              }
            },
            processResults: function (data) {
              return { results: data.results }
            }
          }
        })
      }

      $el.addClass('lookupd')
    })
  }
})(jQuery)
