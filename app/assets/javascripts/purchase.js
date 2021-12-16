$(function() {

  function price() {
    var p = 0

    $('select[name^=quantities]').each(function() {
      p += (parseInt($(this).val()) * parseFloat($(this).attr('data-price')))
    })

    if ($('#percentage_discount').length > 0 && $('#percentage_discount').val() != '')
      p = (p * (100 - parseInt($('#percentage_discount').val())) / 100)

    if ($('#discount').length > 0 && $('#discount').val() != '')
      p = (p * (100 - parseInt($('#discount').val())) / 100)

    if ($('#donation_amount').length > 0 && $('#donation_amount').val() != '')
      p += parseFloat($('#donation_amount').val())

    return p
  }

  function credit() {
    var c = 0

    if ($('#credit').length > 0 && $('#credit').val() != '')
      c += parseFloat($('#credit').val())

    if ($('#fixed_discount').length > 0 && $('#fixed_discount').val() != '')
      c += parseFloat($('#fixed_discount').val())

    return c
  }

  function balance() {
    var b = price() - credit()
    if (b < 0)
      b = 0
    return b
  }

  function setTotal() {
    var p = price()
    var c = credit()
    var b = balance()

    $('#totalDisplay').val((+p).toFixed(2))
    $('#balance').val((+b).toFixed(2))
    if (p == 0) {
      $('#details form button[data-payment-method=rsvp]').show()
      $('#details form button[data-payment-method=stripe]').hide()
      $('#details form button[data-payment-method=coinbase]').hide()
      $('#details form button[data-payment-method=seeds]').hide()
      $('#details form button[data-payment-method=xdai]').hide()
    } else if (b == 0) {
      $('#details form button[data-payment-method=rsvp]').show().find('span').text('Use credit')
      $('#details form button[data-payment-method=stripe]').hide()
      $('#details form button[data-payment-method=coinbase]').hide()
      $('#details form button[data-payment-method=seeds]').hide()
      $('#details form button[data-payment-method=xdai]').hide()
    } else if (b > 0) {
      $('#balance').val((+b).toFixed(2))
      var via_card
      if (coinbase || seedsUsername || xdaiAddress)
        via_card = ' via card'
      else
        via_card = ''
      $('#details form button[data-payment-method]:eq(1)').removeClass('btn-dotted')
      $('#details form button[data-payment-method=rsvp]').hide()
      $('#details form button[data-payment-method=stripe]').show().find('span').text('Pay ' + currencySymbol + (+b).toFixed(2) + via_card)
      $('#details form button[data-payment-method=coinbase]').show()
      $('#details form button[data-payment-method=seeds]').show()
      $('#details form button[data-payment-method=xdai]').show()
    }

  }
  $('select[name^=quantities], #donation_amount').change(function() {
    setTotal()
  })
  setTotal()

  $('#details form button[data-payment-method]').click(function() {
    $('input[type=hidden][name=payment_method]').attr('disabled', true)
    $('input[type=hidden][name=payment_method][value=' + $(this).attr('data-payment-method') + ']').removeAttr('disabled')
    $(this).attr('data-payment-method-clicked', true)
  })

  $('#details form').on('keyup keypress', function(e) {
    var keyCode = e.keyCode || e.which;
    if (keyCode === 13) {
      e.preventDefault();
      return false;
    }
  });

  $('#donation_amount').blur(function() {
    if ($('#donation_amount').val().length > 0) {
      var donationAmount = parseFloat($('#donation_amount').val())
      $('#donation_amount').val(donationAmount.toFixed(2).endsWith('00') ? donationAmount.toFixed(0) : donationAmount.toFixed(2))
    }
  }).blur()

  $('#details form').submit(function() {

    var numberOfTickets = 0
    $('select[name^=quantities]').each(function() {
      numberOfTickets += parseInt($(this).val())
    })
    if (numberOfTickets == 0) {
      alert('Please select at least one ticket')
      return false
    }

    if (placesRemaining) {
      if (numberOfTickets > placesRemaining) {
        alert('Please select a maximum of ' + placesRemaining + (placesRemaining == 1 ? ' ticket' : ' tickets'))
        return false
      }
    }

    if (typeof timeAgo !== 'undefined') {
      if (!confirm('This event started ' + timeAgo + ' ago. Press OK to continue, or Cancel to go back.'))
        return false
    }

    if (!signedIn) {
      if (!confirm('You entered your email address as ' + $('#account_email').val() + '. Press OK to continue, or Cancel to go back.'))
        return false
    }

    $('#total').val($('#totalDisplay').val())
    $('#details form button[data-payment-method-clicked] i').show()

    $.post('/events/' + eventId + '/purchase', {
      ticketForm: $('#ticket-types form').serializeObject(),
      detailsForm: $('#details form').serializeObject()
    }, function(data) {
      if (balance() > 0) {
        if (data['session_id']) {
          // Stripe
          var stripe = Stripe(stripePk);
          stripe.redirectToCheckout({
            sessionId: data['session_id']
          })
        } else if (data['checkout_id']) {
          // Coinbase
          window.location = 'https://commerce.coinbase.com/checkout/' + data['checkout_id']
        } else if (data['seeds_secret']) {
          // SEEDS
          $('#select-tickets').hide()
          $('#pay-with-seeds').show()
          $('#pay-with-seeds').find('.card-body p.lead.please').html('Open the SEEDS app and send <strong>' + data['seeds_value'] + ' SEEDS</strong> to <strong>' + seedsUsername + '</strong> with the memo')
          $('#pay-with-seeds').find('.card-body p.lead.memo').html(data['seeds_secret'])
          var offset = $('#pay-with-seeds').offset()
          window.scrollTo(0, offset['top'] - $('#header').height() - 10);
          setInterval(function() {
            if (Date.now() < data['order_expiry'])
              $.getJSON('/events/' + eventId + '/orders/' + data['order_id'] + '/payment_completed', function(_data) {
                if (_data['payment_completed'])
                  window.location = '?success=true&order_id=' + data['order_id']
              })
          }, 30 * 1000);
        } else if (data['xdai_secret']) {
          // xDai
          $('#select-tickets').hide()
          $('#pay-with-xdai').show()
          $('#pay-with-xdai').find('.card-body p.lead.please').html('Send EXACTLY <strong>' + data['xdai_value'] + ' ' + currency + '</strong> to <strong>' + xdaiAddress + '</strong>')
          var offset = $('#pay-with-xdai').offset()
          window.scrollTo(0, offset['top'] - $('#header').height() - 10);

          var web3 = new Web3(ethereum);

          web3.eth.net.getId().then(networkId => {
            if (networkId != 100) {
              $('#pay-with-xdai').find('.card-body p.metamask').html('<mark>Please switch to xDai</mark>')
              ethereum.on('chainChanged', function() {
                console.log('chainChanged')
                web3.eth.net.getId().then(networkId => {
                  if (networkId == 100)
                    connectMetamask()
                })
              });
            } else if (networkId == 100) {
              connectMetamask()
            }
          })

          function connectMetamask() {
            if (!ethereum.selectedAddress) {
              console.log('connecting')
              $('#pay-with-xdai').find('.card-body p.metamask').html('<a href="javascript:;">Connect to Metamask</a>')
              $('#pay-with-xdai').find('.card-body p.metamask a').click(function() {
                ethereum.request({
                  method: 'eth_requestAccounts'
                }).then(pay)
              }).click()
            } else {
              pay()
            }
          }

          function pay() {
            console.log('paying')
            $('#pay-with-xdai').find('.card-body p.metamask').remove()

            var abi = [{
              "constant": false,
              "inputs": [{
                  "name": "_to",
                  "type": "address"
                },
                {
                  "name": "_value",
                  "type": "uint256"
                }
              ],
              "name": "transfer",
              "outputs": [{
                "name": "",
                "type": "bool"
              }],
              "type": "function"
            }];

            var toAddress = xdaiAddress
            var fromAddress = ethereum.selectedAddress
            var amount = parseInt(data['xdai_wei']).toString()

            var contractInstance = new web3.eth.Contract(abi, contractAddress);
            contractInstance.methods.transfer(toAddress, amount).send({
              from: fromAddress
            })
          }

          setInterval(function() {
            if (Date.now() < data['order_expiry'])
              $.getJSON('/events/' + eventId + '/orders/' + data['order_id'] + '/payment_completed', function(_data) {
                if (_data['payment_completed'])
                  window.location = '?success=true&order_id=' + data['order_id']
              })
          }, 30 * 1000);
        }
      } else {
        // RSVP
        window.location = '?success=true&order_id=' + data['order_id']
      }
    }).fail(function() {
      $('#select-tickets, #details').hide()
      $('#card-error').show()
    })

    return false
  });
});
