$(function () {
  'use strict'

  // Constants
  const OPACITY_LOADING = '0.3'
  const OPACITY_LOADED = '1'

  // ─────────────────────────────────────────────────────────────
  // Page Visibility Tracking
  // ─────────────────────────────────────────────────────────────

  let pageIsVisible = !document.hidden
  let pendingRefreshOnVisible = false

  document.addEventListener('visibilitychange', function () {
    pageIsVisible = !document.hidden

    // When page becomes visible again, refresh all pagelets that missed updates
    if (pageIsVisible && pendingRefreshOnVisible) {
      pendingRefreshOnVisible = false
      $('[data-pagelet-refresh][data-pagelet-refresh-registered]').each(function () {
        const pagelet = $(this)
        if (!pagelet[0].hasAttribute('data-pagelet-refresh-paused') && $.contains(document, pagelet[0])) {
          reloadPagelet(pagelet, function () {
            bindRefreshPauseForPagelet(pagelet)
            refreshAlsoPagelet(pagelet)
          })
        }
      })
    }
  })

  // Cache busting for all AJAX requests
  $.ajaxPrefilter(function (options) {
    const cacheBuster = '_t=' + Date.now()
    options.data = options.data ? options.data + '&' + cacheBuster : cacheBuster
  })

  // ─────────────────────────────────────────────────────────────
  // Helper Functions
  // ─────────────────────────────────────────────────────────────

  function setPageletLoading (pagelet) {
    if (!pagelet.is('[data-pagelet-no-opacity-change]')) {
      pagelet.css('opacity', OPACITY_LOADING)
    }
  }

  function setPageletLoaded (pagelet) {
    if (!pagelet.is('[data-pagelet-no-opacity-change]')) {
      pagelet.css('opacity', OPACITY_LOADED)
    }
  }

  function refreshAlsoPagelet (pagelet) {
    const alsoUrl = pagelet.attr('data-pagelet-also')
    if (alsoUrl) {
      const alsoPagelet = $('[data-pagelet-url="' + alsoUrl + '"]')
      alsoPagelet.load(alsoPagelet.attr('data-pagelet-url'))
    }
  }

  function bindRefreshPauseForPagelet (pagelet) {
    pagelet.find("a[href='javascript:;']").on('click', function () {
      pagelet.attr('data-pagelet-refresh-paused', 'true')
    })
  }

  function reloadPagelet (pagelet, callback) {
    pagelet.load(pagelet.attr('data-pagelet-url'), callback)
  }

  function postLoad (pagelet) {
    setPageletLoaded(pagelet)
    $('.tooltip').remove()
    $('[data-pagelet-refresh-paused]').removeAttr('data-pagelet-refresh-paused')
    refreshAlsoPagelet(pagelet)
  }

  function hasFilesSelected ($form) {
    const $fileInputs = $form.find('input[type=file]')
    if ($fileInputs.length === 0) return false

    const fileValues = $fileInputs.map(function () {
      return $(this).val()
    }).toArray().join('')

    return fileValues !== ''
  }

  // ─────────────────────────────────────────────────────────────
  // Form Submission Handler
  // ─────────────────────────────────────────────────────────────

  $(document).on('submit', '[data-pagelet-url] form:not(.no-trigger)', function () {
    const $form = $(this)
    const pagelet = $form.closest('[data-pagelet-url]')

    setPageletLoading(pagelet)

    if ($form.hasClass('no-submit')) {
      reloadPagelet(pagelet, function () { postLoad(pagelet) })
      return false
    }

    if (hasFilesSelected($form)) {
      // Handle file uploads with FormData
      $.ajax({
        type: 'POST',
        url: $form.attr('action'),
        data: new FormData(this),
        success: function () {
          reloadPagelet(pagelet, function () { postLoad(pagelet) })
        }
      })
    } else {
      // Standard form submission
      $.post($form.attr('action'), $form.serialize(), function () {
        reloadPagelet(pagelet, function () { postLoad(pagelet) })
      })
    }

    return false
  })

  // ─────────────────────────────────────────────────────────────
  // Click Handlers
  // ─────────────────────────────────────────────────────────────

  $(document).on('click', '[data-pagelet-url] a.pagelet-trigger', function () {
    const $link = $(this)

    if ($link.hasClass('no-trigger')) {
      $link.removeClass('no-trigger')
      return false
    }

    const pagelet = $link.closest('[data-pagelet-url]')
    setPageletLoading(pagelet)

    $.get($link.attr('href'), function () {
      reloadPagelet(pagelet, function () { postLoad(pagelet) })
    })

    return false
  })

  $(document).on('click', '[data-pagelet-url] .pagination a', function () {
    // Allow normal navigation in minimal mode
    if (window.location.search.includes('minimal=')) {
      return true
    }

    const $link = $(this)
    const pagelet = $link.closest('[data-pagelet-url]')

    setPageletLoading(pagelet)

    if (pagelet.attr('data-pagelet-refresh')) {
      pagelet.attr('data-pagelet-refresh-paused', 'true')
    }

    pagelet.load($link.attr('href'), function () {
      setPageletLoaded(pagelet)
      $('.tooltip').remove()

      if (pagelet.attr('data-pagelet-scroll') !== 'false') {
        const headerHeight = $('#header').length ? $('#header').height() : 0
        const scrollTarget = pagelet.offset().top - headerHeight - 20
        window.scrollTo(0, scrollTarget)
      }
    })

    return false
  })

  // ─────────────────────────────────────────────────────────────
  // Auto-refresh Pagelets
  // ─────────────────────────────────────────────────────────────

  function initPageletRefresh () {
    $('[data-pagelet-refresh]:not([data-pagelet-refresh-registered])').each(function () {
      const pagelet = $(this)
      pagelet.attr('data-pagelet-refresh-registered', 'true')

      function performRefresh () {
        // Stop refreshing if pagelet was removed from DOM (prevents memory leak)
        if (!$.contains(document, pagelet[0])) {
          clearInterval(intervalId)
          return
        }

        // Skip refresh if page is not visible (tab in background)
        if (!pageIsVisible) {
          pendingRefreshOnVisible = true
          return
        }

        if (!pagelet[0].hasAttribute('data-pagelet-refresh-paused')) {
          reloadPagelet(pagelet, function () {
            bindRefreshPauseForPagelet(pagelet)
            refreshAlsoPagelet(pagelet)
          })
        }
      }

      bindRefreshPauseForPagelet(pagelet)

      const refreshInterval = parseInt(pagelet.attr('data-pagelet-refresh'), 10) * 1000
      const intervalId = setInterval(performRefresh, refreshInterval)
    })
  }

  // ─────────────────────────────────────────────────────────────
  // Lazy Loading Empty Pagelets
  // ─────────────────────────────────────────────────────────────

  function loadEmptyPagelets () {
    $('[data-pagelet-url]:not([data-pagelet-loaded])').each(function () {
      const pagelet = $(this)
      const hasPlaceholder = pagelet[0].hasAttribute('data-with-placeholder')
      const isEmpty = pagelet.html().length === 0

      if (!isEmpty && !hasPlaceholder) return

      if (hasPlaceholder) {
        pagelet.removeAttr('data-with-placeholder')
      } else {
        // Insert loading spinner
        const loadingSpinner = '<i class="pagelet-loading bi bi-spin bi-slash-lg"></i>'

        if (pagelet.is('tr')) {
          const $table = pagelet.closest('table')
          const colCount = $table.find('thead th').length ||
            $table.find('tr:first th').length || 1
          pagelet.html('<td colspan="' + colCount + '">' + loadingSpinner + '</td>')
        } else {
          pagelet.html(loadingSpinner)
        }
      }

      pagelet.attr('data-pagelet-loaded', 'true')
      reloadPagelet(pagelet)
    })
  }

  // ─────────────────────────────────────────────────────────────
  // Initialize
  // ─────────────────────────────────────────────────────────────

  $(document).ajaxComplete(function () {
    initPageletRefresh()
    loadEmptyPagelets()
  })

  // Initial load
  initPageletRefresh()
  loadEmptyPagelets()
})
