/* global $ */

(function () {
  var POLL_MS = 750
  var TIMEOUT_MS = 120000

  var root = document.getElementById('deepwiki-answer')
  if (!root || root.getAttribute('data-deepwiki-done') === 'true') return

  var url = root.getAttribute('data-deepwiki-stream')
  if (!url) return

  var reduceMotion = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches
  var targetHtml = ''
  var targetChars = 0
  var shownChars = textLength(root.querySelector('.docs-deepwiki-answer'))
  var done = false
  var failed = false
  var pollTimer = null
  var tickTimer = null
  var timeoutTimer = null

  function textLength (el) {
    return el ? (el.textContent || '').length : 0
  }

  function htmlTextLength (html) {
    var div = document.createElement('div')
    div.innerHTML = html || ''
    return textLength(div)
  }

  function htmlUpTo (html, maxChars) {
    var div = document.createElement('div')
    div.innerHTML = html || ''
    var left = maxChars

    var walk = function (node) {
      if (left <= 0) {
        if (node.parentNode) node.parentNode.removeChild(node)
        return
      }
      if (node.nodeType === 3) {
        if (node.data.length > left) node.data = node.data.slice(0, left)
        left -= node.data.length
        return
      }
      if (node.nodeType !== 1) return
      var children = Array.prototype.slice.call(node.childNodes)
      for (var i = 0; i < children.length; i++) walk(children[i])
    }

    var children = Array.prototype.slice.call(div.childNodes)
    for (var i = 0; i < children.length; i++) walk(children[i])
    return div.innerHTML
  }

  function sourceUrl () {
    return $('#deepwiki-source a').attr('href') || ''
  }

  function render () {
    if (failed) {
      var href = sourceUrl()
      var link = href
        ? ' <a target="_blank" rel="noopener noreferrer" href="' + href + '">Try it on DeepWiki</a>.'
        : ''
      root.innerHTML = '<div class="alert alert-danger">DeepWiki couldn\'t finish this answer.' + link + '</div>'
      return
    }
    if (!targetHtml) return

    var html = (done && shownChars >= targetChars) || reduceMotion ? targetHtml : htmlUpTo(targetHtml, shownChars)
    root.innerHTML = '<div class="docs-deepwiki-answer">' + html + '</div>'
  }

  function step () {
    if (failed) return
    if (shownChars < targetChars) {
      var behind = targetChars - shownChars
      var jump = reduceMotion ? behind : (behind > 400 ? 28 : behind > 80 ? 10 : 3)
      shownChars = Math.min(targetChars, shownChars + jump)
      render()
    } else if (done) {
      render()
      stop()
    }
  }

  function stopPolling () {
    if (pollTimer) window.clearTimeout(pollTimer)
    pollTimer = null
  }

  function schedulePoll () {
    if (failed || done) return
    pollTimer = window.setTimeout(poll, POLL_MS)
  }

  function fail () {
    if (done) {
      stopPolling()
      return
    }
    failed = true
    render()
    stop()
  }

  function requestFailed (xhr) {
    var status = xhr.status
    if (status === 0 || status === 408 || status === 429 || status >= 500) return
    fail()
  }

  function poll () {
    if (failed || done) return
    pollTimer = null

    $.getJSON(url).done(function (data) {
      if (failed) return

      failed = !!data.failed
      done = !!data.done
      if (failed) {
        render()
        stop()
        return
      }
      if (data.html && data.html !== targetHtml) {
        targetHtml = data.html
        targetChars = htmlTextLength(targetHtml)
        if (reduceMotion) shownChars = targetChars
      }
      if (targetHtml) render()
      if (done) stopPolling()
    }).fail(requestFailed).always(schedulePoll)
  }

  function stop () {
    stopPolling()
    if (tickTimer) window.clearInterval(tickTimer)
    if (timeoutTimer) window.clearTimeout(timeoutTimer)
    tickTimer = null
    timeoutTimer = null
    root.setAttribute('data-deepwiki-done', 'true')
    if (done && !failed) $('#deepwiki-source').removeClass('d-none')
    $('#deepwiki-ask').removeClass('d-none')
  }

  poll()
  tickTimer = window.setInterval(step, 30)
  timeoutTimer = window.setTimeout(fail, TIMEOUT_MS)
})()
