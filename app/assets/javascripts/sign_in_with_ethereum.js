$(function() {
    document.title = "Sign in with Ethereum";
    $('button').click()
    var h1 = 'Sign in with Ethereum'
    if (typeof window.ethereum == 'undefined')
      h1 = 'No wallet found.<br /><a style="color: #5363CA" href="https://metamask.io/">Install Metamask</a>'
    $('form').before('<div style="height: 50vh; background-size: cover; background-position: center center; background-image: url(/images/hero.webp)"></div><h1 style="text-align: center; display: block !important" class="mt-5">'+h1+'</h1>')
})
