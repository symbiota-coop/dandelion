module StripeSubscriptionsSync
  ACTIVE_STATUSES = %w[active trialing].freeze

  def self.setup_stripe
    Stripe.api_key = ENV['STRIPE_SK']
    Stripe.api_version = ENV['STRIPE_API_VERSION']
  end

  def self.active?(subscription)
    ACTIVE_STATUSES.include?(subscription.status)
  end

  def self.sync_subscription(subscription, notify: false)
    setup_stripe
    customer = subscription.customer
    customer = Stripe::Customer.retrieve(customer) if customer.is_a?(String)
    email = customer.email
    return unless email

    account = Account.find_by(email: email.downcase)
    return unless account

    if active?(subscription)
      was_subscriber = account.stripe_subscription_id.present?
      account.set(stripe_subscription_id: subscription.id)
      account.send_stripe_subscription_created_notification(subscription) if notify && !was_subscriber
    elsif account.stripe_subscription_id == subscription.id
      account.set(stripe_subscription_id: nil)
      account.send_stripe_subscription_deleted_notification(subscription) if notify
    end
  end

  def self.clear_subscription(subscription, notify: false)
    account = Account.find_by(stripe_subscription_id: subscription.id)
    return unless account

    account.set(stripe_subscription_id: nil)
    account.send_stripe_subscription_deleted_notification(subscription) if notify
  end

  def self.reconcile
    setup_stripe

    active_subscription_ids = []
    email_to_subscription_id = {}
    email_to_subscription_created_at = {}

    Stripe::Subscription.list(
      status: 'active',
      limit: 100,
      expand: ['data.customer']
    ).auto_paging_each do |subscription|
      active_subscription_ids << subscription.id

      customer = subscription.customer
      next unless customer.respond_to?(:email) && customer.email

      email = customer.email.downcase
      existing_created_at = email_to_subscription_created_at[email]
      next if existing_created_at && subscription.created <= existing_created_at

      email_to_subscription_id[email] = subscription.id
      email_to_subscription_created_at[email] = subscription.created
    end

    Account.and(:stripe_subscription_id.ne => nil).each do |account|
      next if active_subscription_ids.include?(account.stripe_subscription_id)

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
