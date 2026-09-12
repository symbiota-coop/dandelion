/* global ethereum */
$(function () {
  document.title = 'Sign in with Ethereum'
  const hasWallet = typeof window.ethereum !== 'undefined'
  const $heading = $('<h1 style="text-align: center; display: block !important" class="mt-5"></h1>')
  $('form').before('<div style="height: 50vh; background-size: cover; background-position: center center; background-image: url(/images/ethereum.webp)"></div>', $heading)

  if (!hasWallet) {
    $heading.html('No wallet found.<br /><a style="color: #2E63EF" href="https://zerion.io/download">Install Zerion Wallet</a>')
    return
  }

  $heading.text('Sign in with Ethereum')

  const form = document.querySelector('form')
  const template = document.getElementById('siwe_template')

  function toHex (str) {
    return '0x' + Array.from(new TextEncoder().encode(str), function (b) { return b.toString(16).padStart(2, '0') }).join('')
  }

  async function signIn () {
    const accounts = await ethereum.request({ method: 'eth_requestAccounts' })
    const address = accounts[0]
    // The server-rendered EIP-4361 message carries a zero-address placeholder because it cannot know the wallet address in advance
    const message = template.value.replace(template.dataset.placeholder, address)
    const signature = await ethereum.request({ method: 'personal_sign', params: [toHex(message), address] })
    document.getElementById('siwe_message').value = message
    document.getElementById('siwe_signature').value = signature
    form.submit()
  }

  $('button').on('click', function (e) {
    e.preventDefault()
    signIn().catch(function () {
      $heading.html('Signature request was cancelled.<br /><a style="color: #2E63EF" href="javascript:;" onclick="$(\'button\').click()">Try again</a>')
    })
  })
  $('button').click()
})
