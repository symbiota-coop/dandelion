module Dandelion
  module API
    # Each resource is a fixed combination of model, per-account scope and field allowlist.
    # `fields` are readable, filterable and sortable. `private_fields` are readable only.
    # `extras` computes additional readable (never filterable) values per record.
    EVENT_FIELDS = %w[
      id name slug start_time end_time location coordinates time_zone description email currency
      organisation_id activity_id local_group_id evergreen featured has_image created_at updated_at
    ].freeze

    ADMIN_EVENT_FIELDS = (EVENT_FIELDS + %w[
      account_id organiser_id coordinator_id revenue_sharer_id gathering_id capacity
      secret locked browsable show_emails hide_attendees minimal_only
    ]).freeze

    links = ->(path, key = :slug) { ->(record, _account) { { url: "#{ENV['BASE_URI']}/#{path}/#{record.send(key)}", image: record.image&.url } } }

    order_person = ->(order, account) { order.api_hash(account).slice(:name, :firstname, :lastname, :email) }
    ticket_person = ->(ticket, account) { ticket.api_hash(account).slice(:name, :firstname, :lastname, :email, :ordered_for_name, :ordered_for_email, :ticket_type) }

    RESOURCE_DEFINITIONS = {
      'events' => {
        model: 'Event',
        description: 'Public events (not secret, not locked).',
        scope: ->(_account) { Event.live.publicly_visible },
        fields: EVENT_FIELDS,
        extra_fields: %w[url image],
        extras: links.call('e'),
        exclude: %i[embedding]
      },
      'organisations' => {
        model: 'Organisation',
        description: 'Organisations.',
        scope: ->(_account) { Organisation.all },
        fields: %w[id name slug website intro_text location coordinates currency time_zone followers_count has_image created_at updated_at],
        extra_fields: %w[url image],
        extras: links.call('o')
      },
      'gatherings' => {
        model: 'Gathering',
        description: 'Listed, non-secret gatherings.',
        scope: ->(_account) { Gathering.and(listed: true).and(:privacy.ne => 'secret') },
        fields: %w[id name slug location coordinates privacy currency membership_count has_image created_at updated_at],
        extra_fields: %w[url image],
        extras: links.call('g')
      },
      'accounts' => {
        model: 'Account',
        description: 'Public accounts (name and username only).',
        scope: ->(_account) { Account.publicly_visible },
        fields: %w[id name username has_image created_at],
        extra_fields: %w[url image],
        extras: links.call('u', :username)
      },
      'my_orders' => {
        model: 'Order',
        description: 'Your own orders.',
        scope: ->(account) { Order.and(account_id: account.id) },
        fields: %w[
          id event_id value currency payment_completed percentage_discount credit_applied fixed_discount_applied
          opt_in_organisation opt_in_facilitator hear_about via created_at updated_at
        ],
        private_fields: %w[answers]
      },
      'my_tickets' => {
        model: 'Ticket',
        description: 'Your own tickets.',
        scope: ->(account) { Ticket.and(account_id: account.id) },
        fields: %w[id event_id order_id ticket_type_id price discounted_price currency payment_completed show_attendance checked_in checked_in_at created_at updated_at],
        private_fields: %w[name email]
      },
      'admin_events' => {
        model: 'Event',
        description: 'Events you administer, including secret and locked events.',
        scope: ->(account) { Event.administered_by(account) },
        fields: ADMIN_EVENT_FIELDS,
        extra_fields: %w[url image],
        extras: links.call('e'),
        exclude: %i[embedding]
      },
      'admin_orders' => {
        model: 'Order',
        description: 'Completed orders for events you administer. email is included only where you are allowed to view it.',
        scope: ->(account) { account.admin? ? Order.complete : Order.complete.and(:event_id.in => Event.administered_by(account).pluck(:id)) },
        fields: %w[id event_id account_id value currency opt_in_organisation opt_in_facilitator hear_about via created_at updated_at],
        private_fields: %w[answers],
        extra_fields: %w[name firstname lastname email],
        extras: order_person,
        includes: %i[account event]
      },
      'admin_tickets' => {
        model: 'Ticket',
        description: 'Completed tickets for events you administer. Email fields are included only where you are allowed to view them.',
        scope: ->(account) { account.admin? ? Ticket.complete : Ticket.complete.and(:event_id.in => Event.administered_by(account).pluck(:id)) },
        fields: %w[id event_id order_id account_id ticket_type_id price discounted_price currency checked_in checked_in_at created_at updated_at],
        extra_fields: %w[name firstname lastname email ordered_for_name ordered_for_email ticket_type],
        extras: ticket_person,
        includes: %i[account ticket_type order]
      },
      'organisation_followers' => {
        model: 'Organisationship',
        description: 'Followers of organisations you administer.',
        scope: ->(account) { account.admin? ? Organisationship.all : Organisationship.and(:organisation_id.in => Organisation.administered_by(account).pluck(:id)) },
        fields: %w[id organisation_id account_id admin event_manager unsubscribed monthly_donation_amount monthly_donation_currency monthly_donation_start_date created_at updated_at],
        extra_fields: %w[name firstname lastname email],
        extras: ->(organisationship, _account) { organisationship.api_hash.slice(:name, :firstname, :lastname, :email) },
        includes: %i[account]
      }
    }.freeze
  end
end
