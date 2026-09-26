module Dandelion
  module API
    # One resource per collection. Rows come from the model's readable_by(account) policy.
    # `fields` must be safe to show to anyone who can read the row: they are readable, filterable and sortable.
    # `private_fields` are readable only. `extras` computes values whose visibility varies by row (never filterable).
    links = ->(path, key = :slug) { ->(record, _account) { { url: "#{ENV['BASE_URI']}/#{path}/#{record.send(key)}", image: record.image&.url } } }

    order_person = lambda do |order, account|
      person = order.api_hash(account)
      person[:email] = account.email if order.account_id == account.id
      person.slice(:name, :firstname, :lastname, :email)
    end

    ticket_person = lambda do |ticket, account|
      person = ticket.api_hash(account)
      person[:email] = account.email if ticket.account_id == account.id
      person[:ordered_for_email] = ticket.email if ticket.account_id == account.id || ticket.order&.account_id == account.id
      person.slice(:name, :firstname, :lastname, :email, :ordered_for_name, :ordered_for_email, :ticket_type)
    end

    RESOURCE_DEFINITIONS = {
      'events' => {
        model: 'Event',
        description: 'Public events, plus events you administer (including secret and locked events).',
        fields: %w[
          id name slug start_time end_time location coordinates time_zone description email currency
          organisation_id activity_id local_group_id evergreen featured secret locked has_image created_at updated_at
        ],
        extra_fields: %w[url image],
        extras: links.call('e'),
        exclude: %i[embedding]
      },
      'organisations' => {
        model: 'Organisation',
        description: 'Organisations.',
        fields: %w[id name slug website intro_text location coordinates currency time_zone followers_count has_image created_at updated_at],
        extra_fields: %w[url image],
        extras: links.call('o')
      },
      'gatherings' => {
        model: 'Gathering',
        description: 'Listed, non-secret gatherings, plus gatherings you are a member of.',
        fields: %w[id name slug location coordinates privacy listed currency membership_count has_image created_at updated_at],
        extra_fields: %w[url image],
        extras: links.call('g')
      },
      'accounts' => {
        model: 'Account',
        description: 'Public accounts, plus your own (name and username only).',
        fields: %w[id name username has_image created_at],
        extra_fields: %w[url image],
        extras: links.call('u', :username)
      },
      'orders' => {
        model: 'Order',
        description: 'Your own orders, plus completed orders for events you administer. email is included only where you are allowed to view it.',
        fields: %w[id event_id account_id value currency payment_completed opt_in_organisation opt_in_facilitator hear_about via created_at updated_at],
        private_fields: %w[answers],
        extra_fields: %w[name firstname lastname email],
        extras: order_person,
        includes: %i[account event]
      },
      'tickets' => {
        model: 'Ticket',
        description: 'Your own tickets, tickets in orders you placed, plus completed tickets for events you administer. Email fields are included only where you are allowed to view them.',
        fields: %w[id event_id order_id account_id ticket_type_id price discounted_price currency payment_completed checked_in checked_in_at created_at updated_at],
        extra_fields: %w[name firstname lastname email ordered_for_name ordered_for_email ticket_type],
        extras: ticket_person,
        includes: %i[account ticket_type order]
      },
      'organisationships' => {
        model: 'Organisationship',
        description: 'Organisations you follow, plus the followers of organisations you administer.',
        fields: %w[id organisation_id account_id admin event_manager unsubscribed monthly_donation_amount monthly_donation_currency monthly_donation_start_date created_at updated_at],
        extra_fields: %w[name firstname lastname email],
        extras: ->(organisationship, _account) { organisationship.api_hash.slice(:name, :firstname, :lastname, :email) },
        includes: %i[account]
      }
    }.freeze
  end
end
