/* global Stripe, Web3, ethereum */

// eslint-disable-next-line no-unused-vars
function paymentHandlers (config) {
  return {
    rsvp: function (data) {
      window.location = '?success=true&order_id=' + data.order_id
    },

    stripe: function (data) {
      const stripe = config.stripeAccount ? Stripe(config.stripePk, { stripeAccount: config.stripeAccount }) : Stripe(config.stripePk)
      stripe.redirectToCheckout({ sessionId: data.session_id })
    },

    gocardless: function (data) {
      window.location = data.gocardless_billing_request_flow['authorisation_url']
    },

    opencollective: function (data) {
      window.location = 'https://opencollective.com/' + config.organisationOcSlug + '/events/' + config.ocSlug + '/donate?interval=oneTime&amount=' + data.value + '&tags=' + data.oc_secret + '&redirect=' + encodeURIComponent(config.eventUrl + '?success=true&order_id=' + data.order_id)
    },

    evm: function (data) {
      $('#select-tickets').hide()
      $('#pay-with-evm').show()
      $('#pay-with-evm').find('.card-body p.lead.please').html('Send EXACTLY <strong>' + data.value + ' ' + (config.currency == 'USD' ? 'BREAD' : config.currency) + '</strong> to <strong>' + config.evmAddress + '</strong>')
      const offset = $('#pay-with-evm').offset()
      window.scrollTo(0, offset.top - $('#header').height() - 10)

      const web3 = new Web3(ethereum)

      web3.eth.net.getId().then(thisNetworkId => {
        if (thisNetworkId != config.networkId) {
          $('#pay-with-evm').find('.card-body p.web3wallet').html("<mark>Please switch your web3 wallet's network to " + config.networkName + '</mark>')
          ethereum.request({
            method: 'wallet_switchEthereumChain',
            params: [{ chainId: '0x' + config.networkId.toString(16) }]
          })
          ethereum.on('chainChanged', function () {
            web3.eth.net.getId().then(thisNetworkId => {
              if (thisNetworkId == config.networkId) { connectWeb3Wallet() }
            })
          })
        } else if (thisNetworkId == config.networkId) {
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

        const toAddress = config.evmAddress
        const fromAddress = ethereum.selectedAddress
        const amount = parseInt(data.wei).toString()

        const contractInstance = new web3.eth.Contract(abi, config.contractAddress)
        contractInstance.methods.transfer(toAddress, amount).send({
          from: fromAddress
        })
      }

      setInterval(function () {
        if (Date.now() < data.order_expiry) {
          $.getJSON('/events/' + config.eventId + '/orders/' + data.order_id + '/payment_completed', function (_data) {
            if (_data.payment_completed) { window.location = '?success=true&order_id=' + data.order_id }
          })
        }
      }, 10 * 1000)
    }
  }
}
