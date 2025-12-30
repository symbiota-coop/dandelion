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
      } else if (data.checkout_id) {
        // Coinbase
        window.location = 'https://commerce.coinbase.com/checkout/' + data.checkout_id
      } else if (data.evm_secret) {
        // EVM
        $('#owed').hide()
        $('#pay-with-evm').show()
        $('#pay-with-evm').find('.card-body p.lead.please').html('Send EXACTLY <strong>' + data.evm_amount + ' ' + config.currency + '</strong> to <strong>' + config.evmAddress + '</strong>')
        const offset = $('#pay-with-evm').offset()
        window.scrollTo(0, offset.top - $('#header').height() - 10)

        const web3 = new Web3(ethereum)

        web3.eth.net.getId().then(thisNetworkId => {
          if (thisNetworkId != config.networkId) {
            $('#pay-with-evm').find('.card-body p.web3wallet').html("<mark>Please switch your web3 wallet's network to " + config.networkName + '</mark>')
            ethereum.on('chainChanged', function () {
              web3.eth.net.getId().then(thisNetworkId => {
                if (thisNetworkId == config.networkId) { connectWeb3Wallet() }
              })
            })
          } else if (thisNetworkId == config.networkId) {
            connectWeb3Wallet()
          }
        })

        function connectWeb3Wallet () {
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

        function pay () {
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

          const toAddress = config.evmAddress
          const fromAddress = ethereum.selectedAddress
          const amount = parseInt(data.evm_wei).toString()

          const contractInstance = new web3.eth.Contract(abi, config.contractAddress)
          contractInstance.methods.transfer(toAddress, amount).send({
            from: fromAddress
          })
        }

        setInterval(function () {
          if (Date.now() < data.payment_expiry) {
            $.getJSON('/g/' + config.gatheringSlug + '/payments/' + data.payment_id, function (_data) {
              if (_data.payment_completed) { window.location = '/g/' + config.gatheringSlug + '/options' }
            })
          }
        }, 10 * 1000)
      }
    }).fail(function () {
      $('#pay-form').hide()
    }).always(function () {
      $('#pay-form').css('opacity', 1)
    })

    return false
  })
})
