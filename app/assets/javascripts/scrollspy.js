/* exported scrollspy */

// Marks the current section in an index of links to sections of the page (the docs and the design guide).
// The current section is the last whose top has scrolled past the fixed header (its scroll-margin-top), or at the
// bottom of the page, the last on screen. Its links get .active, and each is kept in view within its closest `scroller`.
// Bootstrap's scrollspy marks the lowest section in view instead, so it skips short sections jumped to from the index.
// Returns the update, for when the layout changes without a scroll
window.scrollspy = function (links, scroller) {
  var pairs = $(links).map(function () {
    var target = document.getElementById(decodeURIComponent(this.hash.slice(1)))
    return target ? { link: this, target: target } : null
  }).get()
  var targets = $.uniqueSort(pairs.map(function (pair) { return pair.target }))

  var update = function () {
    var visible = targets.filter(function (target) { return target.getClientRects().length })
    if (!visible.length) return

    var threshold = parseFloat(getComputedStyle(visible[0]).scrollMarginTop) + 8
    var current = null
    // At the bottom of the page, sections too near the end to reach the header count once they're on screen
    var bottom = window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 1
    visible.forEach(function (target) {
      if (target.getBoundingClientRect().top <= (bottom ? window.innerHeight : threshold)) current = target
    })

    pairs.forEach(function (pair) {
      var active = pair.target === current
      pair.link.classList.toggle('active', active)
      if (!active) return

      var parent = $(pair.link).closest(scroller)[0]
      if (!parent) return
      var pr = parent.getBoundingClientRect()
      var r = pair.link.getBoundingClientRect()
      if (r.top < pr.top) parent.scrollTop -= (pr.top - r.top + 8)
      else if (r.bottom > pr.bottom) parent.scrollTop += (r.bottom - pr.bottom + 8)
    })
  }

  var ticking = false
  $(window).on('scroll resize', function () {
    if (ticking) return
    ticking = true
    requestAnimationFrame(function () {
      update()
      ticking = false
    })
  })
  update()

  return update
}
