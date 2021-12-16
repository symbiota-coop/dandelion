$(function() {

  $('#details form button[data-payment-method]').click(function() {
    $('input[type=hidden][name=payment_method]').attr('disabled', true)
    $('input[type=hidden][name=payment_method][value=' + $(this).attr('data-payment-method') + ']').removeAttr('disabled')
    $(this).attr('data-payment-method-clicked', true)
  })

  $('#details form').submit(function() {

    if (!signedIn) {
      if (!confirm('You entered your email address as ' + $('#account_email').val() + '. Press OK to continue, or Cancel to go back.'))
        return false
    }

    $('#details form button[data-payment-method-clicked] i').show()

    $.post('/services/' + serviceId + '/book', {
      bookingForm: $('#booking form').serializeObject(),
      detailsForm: $('#details form').serializeObject()
    }, function(data) {
      if (data['session_id']) {
        var stripe = Stripe(stripePk);
        stripe.redirectToCheckout({
          sessionId: data['session_id']
        })
      } else if (data['booking_id']) {
        window.location = '?success=true&booking_id=' + data['booking_id']
      }
    }).fail(function() {
      $('#details').hide()
      $('#card-error').show()
    })

    return false
  });

});