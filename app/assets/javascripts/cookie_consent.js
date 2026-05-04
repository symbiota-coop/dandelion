function initCookieConsent () {
  const cookieName = 'dandelion_cookie_consent'
  const categories = ['analytics', 'marketing']

  function getConsent () {
    const match = document.cookie.match(new RegExp('(?:^|; )' + cookieName + '=([^;]*)'))
    const raw = match ? decodeURIComponent(match[1]) : null
    if (!raw) return null
    try {
      return JSON.parse(raw)
    } catch (e) {
      return null
    }
  }

  function saveConsent (choices) {
    const previousConsent = getConsent()
    const consent = {
      version: 1,
      necessary: true,
      analytics: !!choices.analytics,
      marketing: !!choices.marketing,
      saved_at: new Date().toISOString()
    }
    const expires = new Date()
    expires.setFullYear(expires.getFullYear() + 1)
    document.cookie = cookieName + '=' + encodeURIComponent(JSON.stringify(consent)) + '; expires=' + expires.toUTCString() + '; path=/; SameSite=Lax'
    clearDeclinedCookies(consent)
    if (previousConsent && categories.some(function (category) { return previousConsent[category] && !consent[category] })) {
      window.location.reload()
      return
    }
    activateConsentedScripts(consent)
    removeBanner()
  }

  function clearDeclinedCookies (consent) {
    if (!consent.marketing) {
      expireCookie('_fbp')
      expireCookie('_fbc')
    }
  }

  function expireCookie (name) {
    document.cookie = name + '=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/; SameSite=Lax'
  }

  function activateConsentedScripts (consent) {
    categories.forEach(function (category) {
      if (!consent[category]) return
      $('script[type="text/plain"][data-cookie-category="' + category + '"]').each(function () {
        const replacement = document.createElement('script')
        $.each(this.attributes, function () {
          if (this.name !== 'type' && this.name !== 'data-cookie-category') {
            replacement.setAttribute(this.name, this.value)
          }
        })
        replacement.text = this.text
        this.parentNode.replaceChild(replacement, this)
      })
    })
  }

  function removeBanner () {
    $('#cookie-consent').addClass('d-none')
  }

  function showBanner (settingsOpen) {
    const consent = getConsent() || { analytics: false, marketing: false }
    const banner = $('#cookie-consent')
    if (!banner.length) return

    banner.find('[data-cookie-choice="analytics"]').prop('checked', !!consent.analytics)
    banner.find('[data-cookie-choice="marketing"]').prop('checked', !!consent.marketing)
    banner.find('.cookie-consent__settings').toggleClass('d-none', !settingsOpen)
    banner.find('[data-cookie-action="reject"]').toggleClass('d-none', settingsOpen)
    banner.find('[data-cookie-action="customize"]').toggleClass('d-none', settingsOpen)
    banner.find('[data-cookie-action="save"]').toggleClass('d-none', !settingsOpen)
    banner.removeClass('d-none')
    if (settingsOpen) banner.find('[data-cookie-choice="analytics"]').focus()
  }

  const consent = getConsent()
  if (consent) {
    activateConsentedScripts(consent)
  } else {
    showBanner(false)
  }

  $(document).on('click', '.cookie-consent-preferences', function (e) {
    e.preventDefault()
    showBanner(true)
  })

  $(document).on('click', '#cookie-consent [data-cookie-action]', function () {
    const action = $(this).data('cookie-action')
    if (action === 'accept') {
      saveConsent({ analytics: true, marketing: true })
    } else if (action === 'reject') {
      saveConsent({ analytics: false, marketing: false })
    } else if (action === 'customize') {
      showBanner(true)
    } else {
      saveConsent({
        analytics: $('#cookie-consent [data-cookie-choice="analytics"]').prop('checked'),
        marketing: $('#cookie-consent [data-cookie-choice="marketing"]').prop('checked')
      })
    }
  })
}

$(function () {
  initCookieConsent()
})
