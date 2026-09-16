/* global Stripe, runEvmPaymentFlow */

function redirectToCheckout (config, url) {
  if (config.embedded && url) {
    window.open(url, '_blank')
    return
  }
  window.location = url
}

// eslint-disable-next-line no-unused-vars
function eventPaymentHandlers (config) {
  return {
    rsvp: function (data) {
      window.location = '?success=true&order_id=' + data.order_id
    },

    stripe: function (data) {
      if (config.embedded && data.session_url) {
        window.open(data.session_url, '_blank')
        return
      }
      const stripe = config.stripeAccount ? Stripe(config.stripePk, { stripeAccount: config.stripeAccount }) : Stripe(config.stripePk)
      stripe.redirectToCheckout({ sessionId: data.session_id })
    },

    opencollective: function (data) {
      window.location = 'https://opencollective.com/' + config.organisationOcSlug + '/events/' + config.ocSlug + '/donate?interval=oneTime&amount=' + data.value + '&tags=' + data.oc_secret + '&redirect=' + encodeURIComponent(config.eventUrl + '?success=true&order_id=' + data.order_id)
    },

    evm: function (data) {
      runEvmPaymentFlow(config, data, {
        pollUrl: '/events/' + config.eventId + '/orders/' + data.order_id + '/payment_completed',
        onComplete: function () { window.location = '?success=true&order_id=' + data.order_id }
      })
    },

    default: function (data) {
      redirectToCheckout(config, data.redirect_url)
    }
  }
}
