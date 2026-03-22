/* global Web3, ethereum */

/**
 * Shared EVM checkout UI + wallet transfer + completion polling (events + gatherings).
 * @param {object} config - evmAddress, contractAddress, networkId, networkName, currency
 * @param {object} data - value, wei, order_expiry or payment_expiry (ms since epoch as string)
 * @param {object} options
 * @param {string} options.pollUrl - GET JSON with { payment_completed: boolean }
 * @param {function} options.onComplete - called when payment is confirmed
 */
// eslint-disable-next-line no-unused-vars
function runEvmPaymentFlow (config, data, options) {
  const expiryMs = parseInt(data.order_expiry || data.payment_expiry, 10)

  $('#select-tickets').hide()
  $('#owed').hide()
  const displayUnit = config.currency === 'USD' ? 'BREAD' : config.currency
  $('#pay-with-evm').show()
  $('#pay-with-evm').find('.card-body p.lead.please').html('Send EXACTLY <strong>' + data.value + ' ' + displayUnit + '</strong> to <strong>' + config.evmAddress + '</strong>')
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
    if (Date.now() < expiryMs) {
      $.getJSON(options.pollUrl, function (_data) {
        if (_data.payment_completed) { options.onComplete() }
      })
    }
  }, 10 * 1000)
}
