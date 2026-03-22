/* global gatheringPaymentHandlers */

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

    const handlers = gatheringPaymentHandlers(config)
    const method = $('input[type=hidden][name=payment_method]:not(:disabled)').val()

    $.post('/g/' + config.gatheringSlug + '/pay', $(this).serializeObject(), function (data) {
      handlers[method](data)
    }).fail(function () {
      $('#pay-form').hide()
    }).always(function () {
      $('#pay-form').css('opacity', 1)
    })

    return false
  })
})
