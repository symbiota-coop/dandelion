/* global Stripe, runEvmPaymentFlow */

// eslint-disable-next-line no-unused-vars
function gatheringPaymentHandlers (config) {
  return {
    stripe: function (data) {
      const stripe = Stripe(config.stripePk)
      stripe.redirectToCheckout({ sessionId: data.session_id })
    },

    evm: function (data) {
      runEvmPaymentFlow(config, data, {
        pollUrl: '/g/' + config.gatheringSlug + '/payments/' + data.payment_id,
        onComplete: function () { window.location = '/g/' + config.gatheringSlug + '/options' }
      })
    }
  }
}
