/* global ethereum */

/**
 * Shared EVM checkout UI + wallet transfer + completion polling (events + gatherings). Talks to the wallet directly
 * (EIP-1193 requests), with no web3 library.
 * @param {object} config - evmAddress, contractAddress, networkId, networkName, currency
 * @param {object} data - value, wei (a string, as it can be past 2^53), order_expiry or payment_expiry (ms since epoch as string)
 * @param {object} options
 * @param {string} options.pollUrl - GET JSON with { payment_completed: boolean }
 * @param {function} options.onComplete - called when payment is confirmed
 */
function runEvmPaymentFlow (config, data, options) {
  const expiryMs = parseInt(data.order_expiry || data.payment_expiry, 10)

  $('#select-tickets').hide()
  $('#owed').hide()
  const displayUnit = config.currency === 'USD' ? 'BREAD' : config.currency
  $('#pay-with-evm').show()
  $('#pay-with-evm').find('.card-body p.lead.please').empty().append(
    'Send EXACTLY ',
    $('<strong>').text(data.value + ' ' + displayUnit),
    ' to ',
    $('<strong>').text(config.evmAddress)
  )
  const offset = $('#pay-with-evm').offset()
  window.scrollTo(0, offset.top - $('#header').height() - 10)

  // The wallet's chain, as a number (eth_chainId answers in hex)
  const chainId = function () {
    return ethereum.request({ method: 'eth_chainId' }).then(id => parseInt(id, 16))
  }

  chainId().then(thisNetworkId => {
    if (thisNetworkId !== Number(config.networkId)) {
      $('#pay-with-evm').find('.card-body p.web3wallet').empty().append($('<mark>').text("Please switch your web3 wallet's network to " + config.networkName))
      ethereum.request({
        method: 'wallet_switchEthereumChain',
        params: [{ chainId: '0x' + Number(config.networkId).toString(16) }]
      })
      ethereum.on('chainChanged', function () {
        chainId().then(thisNetworkId => {
          if (thisNetworkId === Number(config.networkId)) { connectWeb3Wallet() }
        })
      })
    } else {
      connectWeb3Wallet()
    }
  })

  const connectWeb3Wallet = function () {
    ethereum.request({ method: 'eth_accounts' }).then(accounts => {
      if (accounts.length) { return pay(accounts[0]) }
      $('#pay-with-evm').find('.card-body p.web3wallet').html('<a href="javascript:;">Connect your web3 wallet</a>')
      $('#pay-with-evm').find('.card-body p.web3wallet a').click(function () {
        ethereum.request({
          method: 'eth_requestAccounts'
        }).then(accounts => pay(accounts[0]))
      }).click()
    })
  }

  // An ERC-20 transfer(address, uint256) call: its selector, then each argument as a 32-byte word
  const transferData = function (toAddress, amount) {
    const word = hex => hex.padStart(64, '0')
    return '0xa9059cbb' + word(toAddress.toLowerCase().replace(/^0x/, '')) + word(amount.toString(16))
  }

  const pay = function (fromAddress) {
    $('#pay-with-evm').find('.card-body p.web3wallet').remove()

    ethereum.request({
      method: 'eth_sendTransaction',
      params: [{
        from: fromAddress,
        to: config.contractAddress,
        data: transferData(config.evmAddress, BigInt(data.wei))
      }]
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
