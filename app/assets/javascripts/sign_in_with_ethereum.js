$(function () {
  document.title = 'Sign in with Ethereum'
  const $heading = $('<h1 style="text-align: center; display: block !important" class="mt-5"></h1>')
  $('form').before('<div style="height: 50vh; background-size: cover; background-position: center center; background-image: url(/images/ethereum.webp)"></div>', $heading)
  $heading.text('Sign in with Ethereum')

  const form = document.querySelector('form')
  const template = document.getElementById('siwe_template')

  function toHex (str) {
    return '0x' + Array.from(new TextEncoder().encode(str), function (b) { return b.toString(16).padStart(2, '0') }).join('')
  }

  // Zerion and other modern wallets announce via EIP-6963 and may never set window.ethereum
  function discoverProvider () {
    return new Promise(function (resolve) {
      const announced = []
      function onAnnounce (event) {
        if (event.detail && event.detail.provider) announced.push(event.detail)
      }
      window.addEventListener('eip6963:announceProvider', onAnnounce)
      window.dispatchEvent(new Event('eip6963:requestProvider'))
      setTimeout(function () {
        window.removeEventListener('eip6963:announceProvider', onAnnounce)
        const zerion = announced.find(function (detail) { return detail.info && detail.info.rdns === 'io.zerion.wallet' })
        resolve((zerion || announced[0] || {}).provider || window.ethereum)
      }, 250)
    })
  }

  async function signIn (provider) {
    const accounts = await provider.request({ method: 'eth_requestAccounts' })
    const address = accounts[0]
    // The server-rendered EIP-4361 message carries a zero-address placeholder because it cannot know the wallet address in advance
    const message = template.value.replace(template.dataset.placeholder, address)
    const signature = await provider.request({ method: 'personal_sign', params: [toHex(message), address] })
    document.getElementById('siwe_message').value = message
    document.getElementById('siwe_signature').value = signature
    form.submit()
  }

  discoverProvider().then(function (provider) {
    if (!provider) {
      $heading.html('No wallet found.<br /><a style="color: #2E63EF" href="https://zerion.io/download">Install Zerion Wallet</a>')
      return
    }
    $('button').on('click', function (e) {
      e.preventDefault()
      signIn(provider).catch(function () {
        $heading.html('Signature request was cancelled.<br /><a style="color: #2E63EF" href="javascript:;" onclick="$(\'button\').click()">Try again</a>')
      })
    })
    $('button').click()
  })
})
