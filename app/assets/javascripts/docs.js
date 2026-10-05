/* global hljs */

(function() {
  $('#doc-body pre code').each(function() { hljs.highlightElement(this) })

  var $layout = $('#docs-layout')
  var $inputs = $('.doc-search-input')
  var $results = $('#doc-search-results')
  var MIN_TERM_LENGTH = 2
  var MAX_RESULTS = 30
  var SNIPPET_RADIUS = 90
  var indexEl = document.getElementById('doc-search-index')
  var docIndex = indexEl ? JSON.parse(indexEl.textContent) : []

  // scrollspy.js is deferred, so it's ready once the DOM is
  var updateIndex = function() {}
  $(function() {
    updateIndex = scrollspy('.doc-link', '#sticky-index .doc-index-headings, #sticky-index')
  })

  var parseTerms = function(query) {
    return query.toLowerCase().split(/\s+/).filter(function(term) { return term.length >= MIN_TERM_LENGTH })
  }
  var termIndex = function(text, term) {
    var down = String(text || '').toLowerCase()
    var i = 0
    var idx
    while ((idx = down.indexOf(term, i)) !== -1) {
      if (idx === 0 || !/[a-z0-9]/.test(down.charAt(idx - 1))) return idx
      i = idx + 1
    }
    return -1
  }
  var snippet = function(text, terms) {
    if (!text) return ''
    var indexes = terms.map(function(term) { return termIndex(text, term) }).filter(function(idx) { return idx !== -1 })
    if (!indexes.length) return text.length > SNIPPET_RADIUS * 2 ? text.slice(0, SNIPPET_RADIUS * 2).trim() + '…' : text
    var idx = Math.min.apply(null, indexes)
    var startAt = Math.max(idx - SNIPPET_RADIUS, 0)
    var endAt = Math.min(idx + SNIPPET_RADIUS, text.length)
    while (startAt > 0 && startAt < idx && text.charAt(startAt) !== ' ') startAt++
    while (endAt < text.length && endAt > idx && text.charAt(endAt - 1) !== ' ') endAt--
    return (startAt > 0 ? '…' : '') + text.slice(startAt, endAt).trim() + (endAt < text.length ? '…' : '')
  }
  var escapeHtml = function(text) {
    return String(text).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
  }
  var highlight = function(text, terms) {
    var escaped = escapeHtml(text)
    if (!terms.length) return escaped
    var pattern = terms.map(function(term) {
      return term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    }).join('|')
    return escaped.replace(new RegExp('(' + pattern + ')', 'gi'), '<mark>$1</mark>')
  }

  var searchDocs = function(terms) {
    return docIndex.filter(function(section) {
      var haystack = (section.heading + ' ' + section.text).toLowerCase()
      return terms.every(function(term) { return termIndex(haystack, term) !== -1 })
    }).map(function(section) {
      var heading = section.heading.toLowerCase()
      var score = 0
      terms.forEach(function(term) {
        if (termIndex(section.pageName.toLowerCase(), term) !== -1) score += 12
        if (termIndex(heading, term) !== -1) score += 8
        if (heading.split(/\W+/).indexOf(term) !== -1) score += 4
        if (termIndex(section.text.toLowerCase(), term) !== -1) score += 1
      })
      return {
        pageName: section.pageName,
        heading: section.heading,
        href: section.href,
        snippet: snippet(section.text, terms),
        score: score,
        pageIndex: section.pageIndex
      }
    }).sort(function(a, b) {
      if (b.score !== a.score) return b.score - a.score
      if (a.pageIndex !== b.pageIndex) return a.pageIndex - b.pageIndex
      return a.heading.length - b.heading.length
    }).slice(0, MAX_RESULTS)
  }

  var renderResults = function(query, terms, results) {
    if (!results.length) {
      $results.html('<p class="text-body-secondary mb-0">No matching docs for &ldquo;' + escapeHtml(query) + '&rdquo;.</p>')
      return
    }
    var html = '<p class="doc-search-count">' + results.length + (results.length === 1 ? ' result' : ' results') + ' for &ldquo;' + escapeHtml(query) + '&rdquo;</p><ul class="doc-search-list">'
    results.forEach(function(result) {
      html += '<li><a href="' + result.href + '" class="doc-search-result">'
      html += '<span class="doc-search-page">' + escapeHtml(result.pageName) + '</span>'
      html += '<span class="doc-search-heading">' + highlight(result.heading, terms) + '</span>'
      if (result.snippet) html += '<span class="doc-search-snippet">' + highlight(result.snippet, terms) + '</span>'
      html += '</a></li>'
    })
    $results.html(html + '</ul>')
  }

  var stopSearch = function() {
    $layout.removeClass('is-searching')
    $results.empty()
    updateIndex()
  }

  var runSearch = function(q, source) {
    q = (q || '').trim()
    $inputs.each(function() {
      if (this !== source && this.value !== q) this.value = q
    })
    if (!q) {
      stopSearch()
      return
    }
    var terms = parseTerms(q)
    if (terms.length) renderResults(q, terms, searchDocs(terms))
    else $results.html('<p class="text-body-secondary mb-0">Keep typing to search.</p>')
    var wasSearching = $layout.hasClass('is-searching')
    $layout.addClass('is-searching')
    if (wasSearching) return
    window.scrollTo(0, 0)
    requestAnimationFrame(function() { window.scrollTo(0, 0) })
  }

  $inputs.on('input', function() { runSearch(this.value, this) })
  $inputs.on('keydown', function(e) {
    if (e.key === 'Escape') {
      $inputs.val('')
      stopSearch()
      $(this).blur()
    } else if (e.key === 'Enter') {
      e.preventDefault()
      var first = $results.find('.doc-search-result')[0]
      if (first) first.click()
    }
  })
  $(document).on('keydown', function(e) {
    if (e.key !== '/') return
    if ($(e.target).is('input, textarea, select, [contenteditable=true]')) return
    e.preventDefault()
    $inputs.filter(':visible').first().focus().select()
  })
  $(document).on('click', '.doc-toc-mobile .doc-link', function() {
    $(this).closest('details').removeAttr('open')
  })
  $(document).on('click', '.doc-search-result', function() {
    var url = new URL(this.href, location.href)
    if (url.pathname !== location.pathname) return
    $inputs.val('')
    stopSearch()
    var heading = document.getElementById(decodeURIComponent((url.hash || '').slice(1)))
    if (!heading) return
    requestAnimationFrame(function() {
      heading.scrollIntoView()
      updateIndex()
    })
  })
})()
