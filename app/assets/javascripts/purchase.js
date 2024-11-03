/* global timeAgo, eventId, eventUrl, placesRemaining, currency, currencySymbol, minimumApplicationFee, stripePk, stripeAccount, coinbase, organisationOcSlug, ocSlug, evmAddress, contractAddress, networkId, networkName, signedIn */

$(function () {
  $('#details form').on('keyup keypress', function (e) {
    const keyCode = e.keyCode || e.which
    if (keyCode === 13 && e.target.tagName !== 'TEXTAREA') {
      e.preventDefault()
      return false
    }
  })

  $('#donation_amount').change(function () {
    if ($('#donation_amount').val().length > 0) {
      const donationAmount = parseFloat($('#donation_amount').val())
      if (donationAmount < 0) {
        $('#donation_amount').val('')
      } else {
        $('#donation_amount').val(donationAmount.toFixed(2).endsWith('00') ? donationAmount.toFixed(0) : donationAmount.toFixed(2))
      }
    }
  }).change()

  function priceWithoutDonation () {
    let p = 0

    $('select[name^=quantities]').each(function () {
      p += (parseInt($(this).val()) * parseFloat($(this).attr('data-price') || 0))
    })

    if ($('#percentage_discount').length > 0 && $('#percentage_discount').val() != '') { p = (p * (100 - parseInt($('#percentage_discount').val())) / 100) }

    if ($('#discount').length > 0 && $('#discount').val() != '') { p = (p * (100 - parseInt($('#discount').val())) / 100) }

    return p
  }

  function price () {
    let p = 0

    p += priceWithoutDonation()

    if ($('#donation_amount').length > 0 && $('#donation_amount').val() != '') { p += parseFloat($('#donation_amount').val()) }

    return p
  }

  function credit () {
    let c = 0

    if ($('#credit').length > 0 && $('#credit').val() != '') { c += parseFloat($('#credit').val()) }

    return c
  }

  function fixedDiscount () {
    let d = 0

    if ($('#fixed-discount').length > 0 && $('#fixed-discount').val() != '') { d += parseFloat($('#fixed-discount').val()) }

    return d
  }

  function balance () {
    let b = price() - credit() - fixedDiscount()
    if (b < 0) { b = 0 }
    return b
  }

  $('#donation_amount').focus(function () {
    $('#donation-percent-buttons button').addClass('btn-outline-secondary').removeClass('btn-secondary selected-percent')
  })

  $('#donation-percent-buttons button').click(function () {
    $('#donation-percent-buttons button').addClass('btn-outline-secondary').removeClass('btn-secondary selected-percent')
    $(this).removeClass('btn-outline-secondary').addClass('btn-secondary selected-percent')
    setTotal()
  })

  function setDonationAmount () {
    let p = priceWithoutDonation()

    let dp = $('#donation-percent-buttons button.selected-percent').data('percent')

    if (typeof dp !== 'undefined') {
      let donationAmount = parseFloat(p * (dp / 100))
      if (minimumApplicationFee && donationAmount < minimumApplicationFee) {
        $('#donation-percent-buttons button').addClass('btn-outline-secondary').removeClass('btn-secondary')
        $('#donation_amount').val(minimumApplicationFee)
      } else {
        $('#donation-percent-buttons button.selected-percent').removeClass('btn-outline-secondary').addClass('btn-secondary')
        $('#donation_amount').val(donationAmount.toFixed(2).endsWith('00') ? donationAmount.toFixed(0) : donationAmount.toFixed(2))
      }
    }
  }

  function setTotal () {
    setDonationAmount()
    const p = price()
    const b = balance()

    $('#totalDisplay').val((+p).toFixed(2))
    $('#balance').val((+b).toFixed(2))
    if (p == 0) {
      $('#details form button[data-payment-method=rsvp]').show()
      $('#details form button[data-payment-method=stripe]').hide()
      $('#details form button[data-payment-method=coinbase]').hide()
      $('#details form button[data-payment-method=opencollective]').hide()
      $('#details form button[data-payment-method=evm]').hide()
    } else if (b == 0) {
      $('#details form button[data-payment-method=rsvp]').show().find('span').text('Use credit')
      $('#details form button[data-payment-method=stripe]').hide()
      $('#details form button[data-payment-method=coinbase]').hide()
      $('#details form button[data-payment-method=opencollective]').hide()
      $('#details form button[data-payment-method=evm]').hide()
    } else if (b > 0) {
      $('#balance').val((+b).toFixed(2))
      let via_card
      if (coinbase || ocSlug || evmAddress) { via_card = ' via card' } else { via_card = '' }
      $('#details form button[data-payment-method]:eq(1)').removeClass('btn-dotted')
      $('#details form button[data-payment-method=rsvp]').hide()
      $('#details form button[data-payment-method=stripe]').show().find('span').text('Pay ' + currencySymbol + (+b).toFixed(2) + via_card)
      $('#details form button[data-payment-method=coinbase]').show()
      $('#details form button[data-payment-method=opencollective]').show()
      $('#details form button[data-payment-method=evm]').show()
    }

    $('input[type=hidden][name=payment_method]').prop('disabled', true)
    $('input[type=hidden][name=payment_method][value=' + $('#details form button[data-payment-method]:visible').first().attr('data-payment-method') + ']').prop('disabled', false)
  }
  $('select[name^=quantities], #donation_amount').change(function () {
    setTotal()
  })
  setTotal()

  $('#details form button[data-payment-method]').click(function () {
    $('input[type=hidden][name=payment_method]').prop('disabled', true)
    $('input[type=hidden][name=payment_method][value=' + $(this).attr('data-payment-method') + ']').prop('disabled', false)
    $(this).attr('data-payment-method-clicked', true)
  })

  $('#details form').submit(function () {
    if (!$('input[type=hidden][name=payment_method][value=rsvp]').prop('disabled')) {
      setTotal()
    }

    let halt
    $('input[type=checkbox][data-required]').each(function () {
      if (!$(this).is(':checked')) {
        alert($(this).next().text().trim() + ' must be checked')
        halt = true
      }
    })
    if (halt) { return false }

    let numberOfTickets = 0
    $('select[name^=quantities]').each(function () {
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

    if ($('#accepted-terms').length > 0 && !$('#accepted-terms').is(':checked')) {
      alert('You must agree to the terms and conditions to proceed')
      return false
    }

    if (typeof timeAgo !== 'undefined') {
      if (!confirm('This event started ' + timeAgo + ' ago. Press OK to continue, or Cancel to go back.')) { return false }
    }

    if (!signedIn) {
      if (!confirm('You entered your email address as ' + $('#account_email').val() + '. Press OK to continue, or Cancel to go back.')) { return false }
    }

    $('#total').val($('#totalDisplay').val())
    $('#details form button[data-payment-method-clicked] i').show()

    $.post('/events/' + eventId + '/purchase', {
      ticketForm: $('#ticket-types form').serializeObject(),
      detailsForm: $('#details form').serializeObject()
    }, function (data) {
      if (balance() > 0) {
        if (data.session_id) {
          // Stripe
          const stripe = stripeAccount ? Stripe(stripePk, { stripeAccount: stripeAccount }) : Stripe(stripePk)
          stripe.redirectToCheckout({
            sessionId: data.session_id
          })
        } else if (data.checkout_id) {
          // Coinbase
          window.location = 'https://commerce.coinbase.com/checkout/' + data.checkout_id
        } else if (data.oc_secret) {
          // Open Collective
          window.location = 'https://opencollective.com/' + organisationOcSlug + '/events/' + ocSlug + '/donate?interval=oneTime&amount=' + data.value + '&tags=' + data.oc_secret + '&redirect=' + encodeURIComponent(eventUrl + '?success=true&order_id=' + data.order_id)
        } else if (data.evm_secret) {
          // EVM
          $('#select-tickets').hide()
          $('#pay-with-evm').show()
          $('#pay-with-evm').find('.card-body p.lead.please').html('Send EXACTLY <strong>' + data.evm_value + ' ' + (currency == 'USD' ? 'BREAD' : currency) + '</strong> to <strong>' + evmAddress + '</strong>')
          const offset = $('#pay-with-evm').offset()
          window.scrollTo(0, offset.top - $('#header').height() - 10)

          const web3 = new Web3(ethereum)

          web3.eth.net.getId().then(thisNetworkId => {
            if (thisNetworkId != networkId) {
              $('#pay-with-evm').find('.card-body p.web3wallet').html("<mark>Please switch your web3 wallet's network to " + networkName + '</mark>')
              ethereum.request({
                method: 'wallet_switchEthereumChain',
                params: [{ chainId: '0x' + networkId.toString(16) }]
              })
              ethereum.on('chainChanged', function () {
                web3.eth.net.getId().then(thisNetworkId => {
                  if (thisNetworkId == networkId) { connectWeb3Wallet() }
                })
              })
            } else if (thisNetworkId == networkId) {
              connectWeb3Wallet()
            }
          })

          const connectWeb3Wallet = function () {
            if (!ethereum.selectedAddress) {
              $('#pay-with-evm').find('.card-body p.web3wallet').html('<a href="javascript:;">Connect your web3 wallet</a>')
              $('#pay-with-evm').find('.card-body p.web3wallet a').click(function () {
                ethereum.request({
                  method: 'eth_requestAccounts'
                }).then(pay)
              }).click()
            } else {
              pay()
            }
          }

          const pay = function () {
            $('#pay-with-evm').find('.card-body p.web3wallet').remove()

            const abi = [{
              constant: false,
              inputs: [{
                name: '_to',
                type: 'address'
              },
              {
                name: '_value',
                type: 'uint256'
              }
              ],
              name: 'transfer',
              outputs: [{
                name: '',
                type: 'bool'
              }],
              type: 'function'
            }]

            const toAddress = evmAddress
            const fromAddress = ethereum.selectedAddress
            const amount = parseInt(data.evm_wei).toString()

            const contractInstance = new web3.eth.Contract(abi, contractAddress)
            contractInstance.methods.transfer(toAddress, amount).send({
              from: fromAddress
            })
          }

          setInterval(function () {
            if (Date.now() < data.order_expiry) {
              $.getJSON('/events/' + eventId + '/orders/' + data.order_id + '/payment_completed', function (_data) {
                if (_data.payment_completed) { window.location = '?success=true&order_id=' + data.order_id }
              })
            }
          }, 10 * 1000)
        }
      } else {
        // RSVP
        window.location = '?success=true&order_id=' + data.order_id
      }
    }).fail(function () {
      $('#select-tickets, #details').hide()
      $('#card-error').show()
    })

    return false
  })
})
