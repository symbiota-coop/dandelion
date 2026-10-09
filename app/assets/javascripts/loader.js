// Loader: a bar along the top and a spinner, while an ajax GET has taken more than half a second and while leaving the page takes more than a quarter of a second.
// Load it after tabs.js, whose beforeunload handler may ask to stay on the page
$(function () {
  const $loader = window.noLoader ? $() : $('<div class="loader" style="display: none"><div class="loader-bar"></div><div class="loader-spinner"></div></div>').appendTo('body')
  const $loaderBar = $loader.find('.loader-bar')
  let loaderWidth = 0 // 0 to 1
  let loaderFrame = null
  let loaderLastTime = null
  let loaderDone = false
  let loaderRequests = 0

  function setLoaderWidth (width) {
    loaderWidth = width
    $loaderBar.css('transform', 'scaleX(' + width + ')')
  }

  // Each frame, ease towards 90% (over a few seconds) until it's done, then quickly to 100%
  function loaderStep (time) {
    const dt = loaderLastTime === null ? 0 : time - loaderLastTime
    loaderLastTime = time
    const target = loaderDone ? 1 : 0.9
    setLoaderWidth(loaderWidth + (target - loaderWidth) * (1 - Math.exp(-dt / (loaderDone ? 50 : 2500))))
    if (loaderDone && loaderWidth > 0.995) {
      setLoaderWidth(1)
      loaderFrame = null
      $loader.delay(100).fadeOut(150, function () { setLoaderWidth(0) })
    } else {
      loaderFrame = requestAnimationFrame(loaderStep)
    }
  }

  function startLoader () {
    if (loaderFrame && !loaderDone) return
    loaderDone = false
    $loader.stop(true).css('opacity', '').show()
    if (!loaderFrame) {
      setLoaderWidth(0) // it may have been fading out, full
      loaderLastTime = null
      loaderFrame = requestAnimationFrame(loaderStep)
    }
  }

  function stopLoader () {
    if (!loaderFrame) return
    loaderDone = true
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

  // As the user starts navigating away from the page, if the next one is slow to arrive, so fast page loads don't flash the bar
  let leavingTimer = null
  $(window).on('beforeunload', function (e) {
    if (e.isDefaultPrevented()) return // the page may stay
    if (downloadClicked) {
      downloadClicked = false
    } else {
      clearTimeout(leavingTimer)
      leavingTimer = setTimeout(startLoader, 250)
    }
  })

  // Hide the loader as the user leaves the page, so it doesn't show when they press back
  $(window).on('pagehide', function () {
    clearTimeout(leavingTimer)
    cancelAnimationFrame(loaderFrame)
    loaderFrame = null
    $loader.stop(true).hide()
    setLoaderWidth(0)
  })
})
