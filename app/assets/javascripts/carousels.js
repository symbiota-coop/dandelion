// Carousels (events/_carousel.erb, organisations/_carousel.erb) scroll natively, snapping to their items with CSS
// scroll-snap (app.css). This adds the arrows, which page through a screenful of items at a time and wrap round at
// the ends, and a dot for each page, shown only while the items overflow
$(function () {
  function setUpCarousel (carousel) {
    const track = carousel.querySelector('.snap-carousel-track')
    if (!track) return

    const prev = arrow('prev', 'Previous', 'bi-chevron-compact-left')
    const next = arrow('next', 'Next', 'bi-chevron-compact-right')
    const dots = document.createElement('div')
    dots.className = 'snap-carousel-dots'
    carousel.append(prev, next, dots)

    function overflowing () {
      return track.scrollWidth > track.clientWidth + 1
    }

    function atStart () {
      return track.scrollLeft <= 1
    }

    function atEnd () {
      return track.scrollLeft + track.clientWidth >= track.scrollWidth - 1
    }

    function pageCount () {
      return Math.ceil(track.scrollWidth / track.clientWidth - 0.01)
    }

    function currentPage () {
      return atEnd() ? pageCount() - 1 : Math.round(track.scrollLeft / track.clientWidth)
    }

    function drawDots () {
      const count = overflowing() ? pageCount() : 0
      if (dots.children.length !== count) {
        dots.replaceChildren(...Array.from({ length: count }, function (_, i) {
          const dot = document.createElement('button')
          dot.type = 'button'
          dot.setAttribute('aria-label', 'Page ' + (i + 1))
          dot.addEventListener('click', function () { track.scrollTo({ left: i * track.clientWidth }) })
          return dot
        }))
      }
      const page = currentPage()
      Array.from(dots.children).forEach(function (dot, i) {
        if (i === page) dot.setAttribute('aria-current', 'true')
        else dot.removeAttribute('aria-current')
      })
      carousel.classList.toggle('snap-carousel-overflowing', overflowing())
    }

    prev.addEventListener('click', function () {
      if (atStart()) track.scrollTo({ left: track.scrollWidth })
      else track.scrollBy({ left: -track.clientWidth })
    })
    next.addEventListener('click', function () {
      if (atEnd()) track.scrollTo({ left: 0 })
      else track.scrollBy({ left: track.clientWidth })
    })

    track.addEventListener('scroll', drawDots, { passive: true })
    new ResizeObserver(drawDots).observe(track)
    drawDots()
  }

  function arrow (direction, label, icon) {
    const button = document.createElement('button')
    button.type = 'button'
    button.className = 'snap-carousel-' + direction
    button.setAttribute('aria-label', label)
    const i = document.createElement('i')
    i.className = 'bi ' + icon
    button.append(i)
    return button
  }

  onContentLoaded(function () {
    $('.snap-carousel').once('snap-carousel').each(function () { setUpCarousel(this) })
  })
})
