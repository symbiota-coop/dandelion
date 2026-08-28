module AccountStripeSubscriptions
  extend ActiveSupport::Concern

  KEEP_SUBSCRIPTION_STATUSES = %w[active trialing past_due unpaid].freeze
  CLEAR_SUBSCRIPTION_STATUSES = %w[canceled incomplete_expired].freeze

  class_methods do
    def keep_subscription?(subscription)
      KEEP_SUBSCRIPTION_STATUSES.include?(subscription.status)
    end

    def clear_subscription_status?(subscription)
      CLEAR_SUBSCRIPTION_STATUSES.include?(subscription.status)
    end

    def sync_subscription(subscription, notify: false)
      opts = StripeOpts.call
      customer = subscription.customer
      customer = Stripe::Customer.retrieve(customer, opts) if customer.is_a?(String)
      email = customer.email
      return unless email

      account = Account.find_by(email: email.downcase)
      return unless account

      if keep_subscription?(subscription)
        was_subscriber = account.stripe_subscription_id.present?
        account.set(stripe_subscription_id: subscription.id)
        account.send_stripe_subscription_created_notification(subscription) if notify && !was_subscriber
      elsif clear_subscription_status?(subscription) && account.stripe_subscription_id == subscription.id
        account.set(stripe_subscription_id: nil)
        account.send_stripe_subscription_deleted_notification(subscription) if notify
      end
    end

    def clear_subscription(subscription, notify: false)
      account = Account.find_by(stripe_subscription_id: subscription.id)
      return unless account

      account.set(stripe_subscription_id: nil)
      account.send_stripe_subscription_deleted_notification(subscription) if notify
    end

    def reconcile_stripe_subscriptions
      opts = StripeOpts.call

      kept_subscription_ids = []
      email_to_subscription_id = {}
      email_to_subscription_created_at = {}

      Stripe::Subscription.list(
        { status: 'all', limit: 100, expand: ['data.customer'] },
        opts
      ).auto_paging_each do |subscription|
        next unless keep_subscription?(subscription)

        kept_subscription_ids << subscription.id

        customer = subscription.customer
        next unless customer.respond_to?(:email) && customer.email

        email = customer.email.downcase
        existing_created_at = email_to_subscription_created_at[email]
        next if existing_created_at && subscription.created <= existing_created_at

        email_to_subscription_id[email] = subscription.id
        email_to_subscription_created_at[email] = subscription.created
      end

      Account.and(:stripe_subscription_id.ne => nil).each do |account|
        next if kept_subscription_ids.include?(account.stripe_subscription_id)

        account.set(stripe_subscription_id: nil)
      end

      email_to_subscription_id.each do |email, subscription_id|
        account = Account.find_by(email: email)
        next unless account
        next if account.stripe_subscription_id == subscription_id

        account.set(stripe_subscription_id: subscription_id)
      end
    end
  end
end
