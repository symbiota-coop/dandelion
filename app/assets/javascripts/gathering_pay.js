/* global Stripe, Web3, ethereum */

$(function () {
  const config = (function () {
    try {
      const el = document.getElementById('gathering-pay-config')
      if (el) { return JSON.parse(el.textContent || '{}') }
    } catch (e) { }
    return {}
  })()

  $('#pay-form button[data-payment-method]').click(function () {
    $('input[type=hidden][name=payment_method]').attr('disabled', true)
    $('input[type=hidden][name=payment_method][value=' + $(this).attr('data-payment-method') + ']').removeAttr('disabled')
    $(this).attr('data-payment-method-clicked', true)
  })

  $('#pay-form').submit(function () {
    $('#pay-form button[data-payment-method-clicked] i').show()
    $.post('/g/' + config.gatheringSlug + '/pay', $(this).serializeObject(), function (data) {
      if (data.session_id) {
        // Stripe
        const stripe = Stripe(config.stripePk)
        stripe.redirectToCheckout({ sessionId: data.session_id })
      } else if (data.evm_secret) {
        runEvmPaymentFlow(config, data, {
          pollUrl: '/g/' + config.gatheringSlug + '/payments/' + data.payment_id,
          onComplete: function () { window.location = '/g/' + config.gatheringSlug + '/options' }
        })
      }
    }).fail(function () {
      $('#pay-form').hide()
    }).always(function () {
      $('#pay-form').css('opacity', 1)
    })

    return false
  })
})
