/* global Stripe */

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
      runEvmPaymentFlow(config, data, {
        pollUrl: '/events/' + config.eventId + '/orders/' + data.order_id + '/payment_completed',
        onComplete: function () { window.location = '?success=true&order_id=' + data.order_id }
      })
    }
  }
}
