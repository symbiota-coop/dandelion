/* global Stripe, runEvmPaymentFlow */

// Embedded, the provider's page opens in a new tab: the one opened as the button was pressed (paymentWindow), as
// browsers block a tab opened only once the order comes back (Safari always). In case that tab was blocked too, or opened
// out of sight, the form shows a link to the page
function redirectToCheckout (config, url, options) {
  if (config.embedded && url) {
    const paymentWindow = options.paymentWindow
    if (paymentWindow && !paymentWindow.closed) {
      paymentWindow.location = url
    }
    options.showPaymentLink(url)
    return
  }
  window.location = url
}

function eventPaymentHandlers (config, options) {
  options = options || {}
  return {
    rsvp: function (data) {
      window.location = '?success=true&order_id=' + data.order_id
    },

    stripe: function (data) {
      if (config.embedded && data.session_url) {
        redirectToCheckout(config, data.session_url, options)
        return
      }
      const stripe = config.stripeAccount ? Stripe(config.stripePk, { stripeAccount: config.stripeAccount }) : Stripe(config.stripePk)
      stripe.redirectToCheckout({ sessionId: data.session_id })
    },

    opencollective: function (data) {
      window.location = 'https://opencollective.com/' + encodeURIComponent(config.organisationOcSlug) + '/events/' + encodeURIComponent(config.ocSlug) + '/donate?interval=oneTime&amount=' + data.value + '&tags=' + data.oc_secret + '&redirect=' + encodeURIComponent(config.eventUrl + '?success=true&order_id=' + data.order_id)
    },

    evm: function (data) {
      runEvmPaymentFlow(config, data, {
        pollUrl: '/e/' + config.eventSlug + '/orders/' + data.order_id + '/payment_completed',
        onComplete: function () { window.location = '?success=true&order_id=' + data.order_id }
      })
    },

    default: function (data) {
      redirectToCheckout(config, data.redirect_url, options)
    }
  }
}
