$(function () {
  document.title = 'Sign in with Ethereum'
  $('button').click()
  let h1 = 'Sign in with Ethereum'
  if (typeof window.ethereum == 'undefined') { h1 = 'No wallet found.<br /><a style="color: #2E63EF" href="https://zerion.io/download">Install Zerion Wallet</a>' }
  $('form').before('<div style="height: 50vh; background-size: cover; background-position: center center; background-image: url(/images/ethereum.webp)"></div><h1 style="text-align: center; display: block !important" class="mt-5">' + h1 + '</h1>')
})
