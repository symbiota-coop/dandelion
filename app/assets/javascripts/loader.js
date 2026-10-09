// Loader: a bar along the top and a spinner, while an ajax GET has taken more than half a second and while leaving the page.
// Load it after tabs.js, whose beforeunload handler may ask to stay on the page
$(function () {
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
    if (e.isDefaultPrevented()) return // the page may stay
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
})
