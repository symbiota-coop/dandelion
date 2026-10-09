// Tabs: tab bars and breadcrumbs that scroll sideways, the tab named in the URL's hash, and a warning before
// leaving a tabbed form that's been touched
$(function () {
  // Tabs in a .nav-wrapper, and breadcrumbs (.nav-crumbs) on phones, scroll sideways: while there's more
  // to scroll one way, that edge fades and an arrow scrolls it on by most of a width. The active tab is
  // brought into view. Crumbs scroll right to left, where scrollLeft runs from -max to 0
  function navWrappers () {
    $('.nav-wrapper, .nav-crumbs').once('nav-wrapper').each(function () {
      const wrapper = this
      const $scroller = $(wrapper).wrap('<div class="nav-scroller"></div>').parent()
      const arrows = [['start', 'left', 'Scroll left', -1], ['end', 'right', 'Scroll right', 1]].map(function ([edge, icon, label, direction]) {
        return $(`<button type="button" class="nav-scroller-arrow nav-scroller-${edge}" tabindex="-1" aria-label="${label}" style="display: none"><i class="bi bi-chevron-${icon}"></i></button>`)
          .on('click', function () { wrapper.scrollBy({ left: direction * wrapper.clientWidth * 0.75, behavior: window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' }) })
          .appendTo($scroller)
      })
      const update = function () {
        const max = wrapper.scrollWidth - wrapper.clientWidth
        const rtl = getComputedStyle(wrapper).direction === 'rtl'
        const start = wrapper.scrollLeft > (rtl ? -max : 0) + 1
        const end = wrapper.scrollLeft < (rtl ? 0 : max) - 1
        wrapper.classList.toggle('fade-start', start)
        wrapper.classList.toggle('fade-end', end)
        arrows[0].toggle(start)
        arrows[1].toggle(end)
      }
      $(wrapper).on('scroll', update)
      $(window).on('resize', update)
      scrollToActiveTab(wrapper)
      update()
    })
  }

  function scrollToActiveTab (wrapper) {
    const active = $(wrapper).find('.nav-link.active')[0]
    if (!active) return
    if (active.offsetLeft < wrapper.scrollLeft || active.offsetLeft + active.offsetWidth > wrapper.scrollLeft + wrapper.clientWidth) {
      wrapper.scrollLeft = active.offsetLeft - (wrapper.clientWidth - active.offsetWidth) / 2
    }
  }

  function showTabFromHash () {
    const hash = window.location.hash
    if (!hash) return
    const $link = $('a[data-bs-toggle="tab"]').filter(function () {
      return this.hash === hash
    })
    if ($link.length && !$link.hasClass('active')) {
      $link.tab('show')
    }
  }

  $(document).on('shown.bs.tab', 'a[data-bs-toggle="tab"]', function (e) {
    const wrapper = $(e.target).closest('.nav-wrapper')[0]
    if (wrapper) scrollToActiveTab(wrapper)
    const hash = e.target.hash
    if (hash && window.location.hash !== hash) {
      history.replaceState(null, '', hash)
    }
  })

  $(window).on('hashchange', showTabFromHash)

  let navTabsFormSubmitting = false
  let navTabsFormTouched = false
  $(document).on('submit', 'form:has(.nav-tabs)', function () {
    navTabsFormSubmitting = true
  })
  $(document).on('focusin', 'form:has(.nav-tabs) :input, form:has(.nav-tabs) .ck-editor__editable', function () {
    navTabsFormTouched = true
  })

  $(window).on('beforeunload', function (e) {
    if (!navTabsFormSubmitting && navTabsFormTouched && $('form:has(.nav-tabs)').length) {
      // loader.js sees this and doesn't start the loader, since the page may stay
      e.preventDefault()
      e.returnValue = ''
      return ''
    }
  })

  onContentLoaded(function () {
    showTabFromHash()
    navWrappers()
  })
})
