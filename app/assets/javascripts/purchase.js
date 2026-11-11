/* global eventPaymentHandlers */

$(function () {
  const config = (function () {
    try {
      const el = document.getElementById('purchase-config')
      if (el) { return JSON.parse(el.textContent || '{}') }
    } catch { }
    return (window.purchaseConfig || {})
  })()
  const $donationAmount = $('#donation_amount')

  function showPurchaseAlert (message) {
    if (!config.embedded) {
      window.alert(message)
      return
    }
    const $alert = $('#purchase-alert')
    $alert.text(message).show()
    $alert[0].scrollIntoView({ block: 'nearest' })
  }

  function currentDonationAmountValue () {
    return (($donationAmount.val() || '').trim())
  }

  function syncPreviousDonationValue () {
    $donationAmount.data('previousDonationValue', currentDonationAmountValue())
  }

  function setDonationAmountValue (value) {
    $donationAmount.val(value)
    syncPreviousDonationValue()
  }

  $('#details form').on('keyup keypress', function (e) {
    const keyCode = e.keyCode || e.which
    if (keyCode === 13 && e.target.tagName !== 'TEXTAREA') {
      e.preventDefault()
      return false
    }
  })

  $donationAmount.change(function () {
    if ($donationAmount.val().length > 0) {
      const donationAmount = parseFloat($donationAmount.val())
      // A donation to Dandelion is the payment's application fee, which OrderBuilder refuses below the currency's
      // smallest unit (DonationTooSmall). One to the organisation is only added to the total
      if (donationAmount < 0) {
        setDonationAmountValue('')
      } else if (config.donationsToDandelion && donationAmount > 0 && config.minimumApplicationFee && donationAmount < config.minimumApplicationFee) {
        setDonationAmountValue(config.minimumApplicationFee)
      } else {
        setDonationAmountValue(donationAmount.toFixed(2).endsWith('00') ? donationAmount.toFixed(0) : donationAmount.toFixed(2))
      }
    }
  }).change()

  // What the form's choices cost: the server works it out (POST /e/:slug/quote, Quote) and the form shows it. A quote
  // is asked for a moment after the last change, and only the latest one asked for is shown. Until it comes, the
  // totals fade back and the payment buttons wait, so nothing is booked at a price the buyer hasn't seen. Without a
  // quote for the choices as they are (it was refused, or couldn't be had), the buttons stay disabled, as they'd still
  // show the last quote's amount
  let quote = null
  let quoteSequence = 0
  let quoteTimer = null
  let quotePending = false
  let purchaseSubmitting = false
  const QUOTE_RETRIES = 3
  const QUOTE_RETRY_DELAY = 2000

  function syncPaymentButtonsDisabled () {
    $('#details form button[data-payment-method]').prop('disabled', purchaseSubmitting || quotePending || !quote)
  }

  function showQuoteError (message) {
    const $error = $('#quote-error')
    if (message) {
      $error.text(message).show()
    } else {
      $error.hide()
    }
  }

  function setQuotePending (pending) {
    quotePending = pending
    $('#totalDisplay, #balance').attr('aria-busy', pending ? 'true' : null)
    syncPaymentButtonsDisabled()
  }

  // attempt: how many times this quote has been retried after the request failed
  function requestQuote (attempt) {
    attempt = attempt || 0
    clearTimeout(quoteTimer)
    const sequence = ++quoteSequence
    setQuotePending(true)
    $.post('/e/' + config.eventSlug + '/quote', {
      ticketForm: $('#ticket-types form').serializeObject()
    }).done(function (data) {
      if (sequence !== quoteSequence) { return }
      quote = data
      // A percent button's donation follows the tickets' price, so it's asked for again with the new donation
      if (setDonationAmount()) {
        requestQuote()
        return
      }
      showQuoteError(null)
      showQuote()
      setQuotePending(false)
    }).fail(function (xhr) {
      if (sequence !== quoteSequence) { return }
      quote = null
      $('#totalDisplay, #balance').val('')
      const json = xhr.responseJSON
      if (xhr.status >= 400 && xhr.status < 500 && json && json.error) {
        // The choices can't be booked as they are (a price outside its range, say), so the buyer changes them
        showQuoteError(json.error)
        setQuotePending(false)
      } else if (attempt < QUOTE_RETRIES) {
        // The request failed (the connection, or the server): it's tried again, and a change asks afresh
        showQuoteError('Updating the price…')
        quoteTimer = setTimeout(function () { requestQuote(attempt + 1) }, QUOTE_RETRY_DELAY)
      } else {
        showQuoteError("The price couldn't be updated. Check your connection and change your choices, or reload the page, to try again.")
        setQuotePending(false)
      }
    })
  }

  function scheduleQuote () {
    clearTimeout(quoteTimer)
    quoteSequence++
    setQuotePending(true)
    quoteTimer = setTimeout(requestQuote, 250)
  }

  $donationAmount.focus(function () {
    $('#donation-percent-buttons button').removeClass('active selected-percent')
  })

  if ($('#donation-percent-buttons').length && $('#donation-cleared-modal').length) {
    let donationClearedModalShown = false

    syncPreviousDonationValue()

    $donationAmount.on('input', function () {
      const previousDonationAmount = parseFloat($donationAmount.data('previousDonationValue'))
      const currentDonationValue = currentDonationAmountValue()

      if (
        currentDonationValue === '' &&
        !isNaN(previousDonationAmount) &&
        previousDonationAmount > 0 &&
        !$('#donation-cleared-modal').hasClass('show') &&
        !donationClearedModalShown
      ) {
        donationClearedModalShown = true
        $('#donation-cleared-modal').modal('show')
      }

      syncPreviousDonationValue()
    })
    $donationAmount.on('change', function () {
      syncPreviousDonationValue()
    })
    $('#donation-cleared-another').on('click', function () {
      $('#donation-cleared-modal').one('hidden.bs.modal', function () {
        $donationAmount.trigger('focus')
      })
      $('#donation-cleared-modal').modal('hide')
    })
    $('#donation-cleared-one').on('click', function () {
      const fee = config.minimumApplicationFee
      if (fee != null) {
        setDonationAmountValue(fee)
        $donationAmount.trigger('change')
      }
      $('#donation_via_modal').val('1')
      syncPreviousDonationValue()
      $('#donation-cleared-modal').modal('hide')
    })
  }

  $('#donation-percent-buttons button').click(function () {
    $('#donation-percent-buttons button').removeClass('active selected-percent')
    $(this).addClass('active selected-percent')
    if (quote) { setDonationAmount() }
    requestQuote()
  })

  // p: the tickets' price after percentage discounts, from the quote
  function updateDonationPercentButtons (p) {
    // Event::DANDELION_DONATION_HIGHER_PRICE_UNITS
    const isHighPrice = config.dandelionDonationHigherPriceOver != null && p > config.dandelionDonationHigherPriceOver

    $('#donation-percent-buttons button').each(function () {
      const $btn = $(this)
      const percent = isHighPrice ? $btn.data('percent-high') : $btn.data('percent')

      if (percent) {
        $btn.text(percent + '%')
        $btn.data('active-percent', percent)
      }
    })
  }

  // The selected percent button's donation, of the quote's tickets. Says whether it changed the donation
  function setDonationAmount () {
    const p = quote.tickets

    updateDonationPercentButtons(p)

    const dp = $('#donation-percent-buttons button.selected-percent').data('active-percent')
    if (typeof dp === 'undefined') { return false }

    const previousValue = currentDonationAmountValue()
    const donationAmount = parseFloat(p * (dp / 100))
    if (config.minimumApplicationFee && donationAmount < config.minimumApplicationFee) {
      $('#donation-percent-buttons button').removeClass('active')
      setDonationAmountValue(config.minimumApplicationFee)
    } else {
      $('#donation-percent-buttons button.selected-percent').addClass('active')
      setDonationAmountValue(donationAmount.toFixed(2).endsWith('00') ? donationAmount.toFixed(0) : donationAmount.toFixed(2))
    }
    return currentDonationAmountValue() !== previousValue
  }

  // Tickets and donation before credit and a fixed discount (Total), and what's left to pay (Balance)
  function showQuote () {
    const p = quote.subtotal
    const b = quote.total

    $('#totalDisplay').val((+p).toFixed(2))
    $('#balance').val((+b).toFixed(2))
    const $rsvp = $('#details form button[data-payment-method=rsvp]')
    const $paid = $('#details form button[data-payment-method]').not($rsvp)
    const $firstPaidButton = $('#details form button[data-payment-method]').eq(1)
    const cardMethods = config.cardMethods || []
    const $card = $('#details form button[data-payment-method]').filter(function () {
      return cardMethods.includes($(this).attr('data-payment-method'))
    })

    if (p === 0) {
      $rsvp.show()
      $paid.hide()
    } else if (!quote.payment_required) {
      $rsvp.show().find('span').text('Use credit')
      $paid.hide()
    } else {
      $firstPaidButton.removeClass('btn-outline-primary').addClass('btn-primary')
      $rsvp.hide()
      $paid.show()
      $card.find('span').text('Pay ' + config.currencySymbol + (+b).toFixed(2) + ' via card')
    }

    const method = $('#details form button[data-payment-method]:visible').first().attr('data-payment-method')
    $('input[type=hidden][name=payment_method]').prop('disabled', true)
      .filter(function () { return this.value === method }).prop('disabled', false)
  }
  $('select[name^=quantities], #donation_amount').change(scheduleQuote)
  requestQuote()

  function syncQuantitySelectPointerEvents ($selects) {
    $selects.each(function () {
      $(this).css('pointer-events', this.disabled ? 'none' : '')
    })
  }
  syncQuantitySelectPointerEvents($('select[name^=quantities]'))
  $(document).on('change', 'select[name^=quantities]', function () {
    syncQuantitySelectPointerEvents($(this))
  })
  $(document).on('click', '.quantity-select-container', function () {
    if ($(this).find('select[name^=quantities]').prop('disabled')) {
      const message = $(this).closest('tr').find('.select-a-price-first').text().trim()
      showPurchaseAlert(message)
    }
  })

  let $ticketTypeWaitlistButton = $()

  $(document).on('click', '.join-ticket-type-waitlist', function (e) {
    e.preventDefault()
    e.stopPropagation()
    if (!config.eventSlug) { return }

    $ticketTypeWaitlistButton = $(this)
    $('#ticket-type-waitlist-ticket-type-id').val($ticketTypeWaitlistButton.data('ticket-type-id'))
    $('#ticket-type-waitlist-error').hide().text('')
    $('#ticket-type-waitlist-modal').modal('show')
  })

  $('#ticket-type-waitlist-modal').on('shown.bs.modal', function () {
    $('#ticket-type-waitlist-name').trigger('focus')
  })

  $('#ticket-type-waitlist-form').on('submit', function (e) {
    e.preventDefault()
    if (!config.eventSlug) { return }

    const name = ($('#ticket-type-waitlist-name').val() || '').trim()
    const email = ($('#ticket-type-waitlist-email').val() || '').trim()

    let recaptchaResponse = ''
    if (config.recaptchaEnabled) {
      recaptchaResponse = window.grecaptcha && window.grecaptcha.getResponse()
      if (!recaptchaResponse) {
        $('#ticket-type-waitlist-error').text('Please confirm you are not a robot.').show()
        return
      }
    }

    $('#ticket-type-waitlist-error').hide().text('')
    $('#ticket-type-waitlist-submit').prop('disabled', true)
    $ticketTypeWaitlistButton.prop('disabled', true)
    $.post('/e/' + config.eventSlug + '/ticket_type_waitships', {
      ticket_type_id: $('#ticket-type-waitlist-ticket-type-id').val(),
      name: name,
      email: email,
      'g-recaptcha-response': recaptchaResponse
    }).done(function () {
      $ticketTypeWaitlistButton.replaceWith($('<span class="text-body-secondary joined-ticket-type-waitlist">Joined waitlist!</span>'))
      $('#ticket-type-waitlist-modal').modal('hide')
    }).fail(function (xhr) {
      $ticketTypeWaitlistButton.prop('disabled', false)
      let msg = 'Something went wrong. Please try again.'
      try {
        const json = xhr.responseJSON || JSON.parse(xhr.responseText || '{}')
        if (json && json.error) { msg = json.error }
      } catch { }
      $('#ticket-type-waitlist-error').text(msg).show()
    }).always(function () {
      $('#ticket-type-waitlist-submit').prop('disabled', false)
      if (config.recaptchaEnabled && window.grecaptcha) { window.grecaptcha.reset() }
    })
  })

  $('#account_phone').on('input blur', function () {
    const phoneValue = $(this).val().trim()
    if (phoneValue.length > 0 && !phoneValue.startsWith('+')) {
      $(this).addClass('is-invalid')
      if (!$(this).next('.invalid-feedback').length) {
        $(this).after('<div class="invalid-feedback">Please start with the +country code (+44 for UK)</div>')
      }
    } else {
      $(this).removeClass('is-invalid')
      $(this).next('.invalid-feedback').remove()
    }
  })

  $('#details form button[data-payment-method]').click(function () {
    const method = $(this).attr('data-payment-method')
    $('input[type=hidden][name=payment_method]').prop('disabled', true)
      .filter(function () { return this.value === method }).prop('disabled', false)
    $(this).attr('data-payment-method-clicked', true)
  })

  // What the buyer has confirmed, embedded, by pressing again: booking again though they have a ticket, and an email
  // that looks mistyped. Both are for the email they confirmed them for
  let embeddedConfirmed = {}
  $('#account_email').on('input', function () {
    embeddedConfirmed = {}
  })
  $(window).on('pageshow', function () {
    purchaseSubmitting = false
    syncPaymentButtonsDisabled()
    $('#details form button[data-payment-method-clicked] i').hide()
  })
  $('#details form').submit(function () {
    if (purchaseSubmitting) { return false }

    if (config.embedded) {
      $('#purchase-alert').hide()
    }

    // OrderBuilder checks the rest (tickets chosen, places left, answers, terms, the phone number's country code, an
    // email that looks mistyped), and the form shows what it says is wrong

    purchaseSubmitting = true
    syncPaymentButtonsDisabled()
    $('#details form button[data-payment-method-clicked] i').show()

    let method = $('input[type=hidden][name=payment_method]:not(:disabled)').val()
    const ticketForm = $('#ticket-types form').serializeObject()
    if (config.donationsToDandelion && !(config.platformDonationMethods || []).includes(method)) {
      ticketForm.donation_amount = ''
      ticketForm.donation_via_modal = '0'
      // The order drops the donation, which can leave nothing to pay
      if (quote && !quote.payment_required_without_donation) {
        method = 'rsvp'
        $('input[type=hidden][name=payment_method]').prop('disabled', true)
        $('input[type=hidden][name=payment_method][value=rsvp]').prop('disabled', false)
      }
    }

    // Embedded, the provider's page opens in a new tab, which has to be opened now, while the button is being pressed:
    // browsers block one opened when the order comes back. It shows a blank page until then, and closes if the order fails
    let paymentWindow = null
    if (config.embedded && !['rsvp', 'evm', 'opencollective'].includes(method)) {
      paymentWindow = window.open('', '_blank')
      if (paymentWindow) {
        paymentWindow.opener = null
      }
    }
    const closePaymentWindow = function () {
      if (paymentWindow) {
        paymentWindow.close()
      }
    }
    const handlers = eventPaymentHandlers(config, {
      paymentWindow: paymentWindow,
      showPaymentLink: function (url) {
        $('#details form button[data-payment-method-clicked] i').hide()
        $('#payment-link a').attr('href', url)
        $('#payment-link').show()
        $('#payment-link')[0].scrollIntoView({ block: 'nearest' })
      }
    })

    // confirmed: what the buyer has confirmed (duplicate, email)
    const postPurchase = function (confirmed) {
      $.post('/e/' + config.eventSlug + '/purchase', {
        ticketForm: ticketForm,
        detailsForm: $('#details form').serializeObject(),
        confirmed_duplicate: confirmed.duplicate ? '1' : '',
        confirmed_email: confirmed.email ? '1' : ''
      }, function (data) {
        // An order OrderBuilder completed without a payment (credit or a fixed discount paid for the tickets) is
        // confirmed, as an RSVP is
        if (data && data.payment_required === false) {
          closePaymentWindow()
          handlers.rsvp(data)
          return
        }
        (handlers[method] || handlers.default)(data)
      }).fail(function (xhr) {
        let json = {}
        try { json = xhr.responseJSON || JSON.parse(xhr.responseText || '{}') || {} } catch { }
        closePaymentWindow()
        const enableForm = function () {
          purchaseSubmitting = false
          syncPaymentButtonsDisabled()
          $('#details form button[data-payment-method-clicked] i').hide()
        }
        // Something to confirm before booking: embedded, by pressing again, as confirm() can't be used there
        const confirmation = (json.duplicate && 'duplicate') || (json.mistyped_email && 'email')
        if (confirmation && !confirmed[confirmation]) {
          enableForm()
          const again = confirmation === 'duplicate' ? 'get another ticket anyway' : 'book with this email address'
          if (config.embedded) {
            embeddedConfirmed[confirmation] = true
            showPurchaseAlert(json.error + ' Press the button again to ' + again + '.')
          } else if (confirm(json.error + ' Press OK to ' + again + ', or Cancel to go back.')) {
            purchaseSubmitting = true
            syncPaymentButtonsDisabled()
            $('#details form button[data-payment-method-clicked] i').show()
            postPurchase(Object.assign({}, confirmed, { [confirmation]: true }))
          } else if (confirmation === 'email') {
            $('#account_email').trigger('focus')
          }
          return
        }
        // OrderBuilder refused the booking, saying why
        if (json.error) {
          enableForm()
          showPurchaseAlert(json.error)
          return
        }
        $('#select-tickets, #details').hide()
        $('#card-error').show()
      })
    }
    postPurchase(config.embedded ? embeddedConfirmed : {})

    return false
  })
})

