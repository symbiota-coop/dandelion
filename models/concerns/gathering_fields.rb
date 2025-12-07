module GatheringFields
  extend ActiveSupport::Concern

  included do
    field :name, type: String
    field :slug, type: String
    field :location, type: String
    field :coordinates, type: Array
    field :image_uid, type: String
    field :image_width_unmagic, type: Integer
    field :image_height_unmagic, type: Integer
    field :has_image, type: Mongoid::Boolean
    field :intro_for_members, type: String
    field :welcome_email, type: String
    field :privacy, type: String
    field :intro_for_non_members, type: String
    field :application_questions, type: String
    field :joining_questions, type: String
    field :fixed_threshold, type: Integer
    field :member_limit, type: Integer
    field :proposing_delay, type: Integer
    field :processed_via_dandelion, type: Integer
    field :balance, type: Float
    field :paypal_email, type: String
    field :currency, type: String
    field :invitations_granted, type: Integer
    field :stripe_endpoint_secret, type: String
    field :stripe_pk, type: String
    field :stripe_sk, type: String
    field :coinbase_api_key, type: String
    field :coinbase_webhook_secret, type: String
    field :evm_address, type: String
    field :redirect_on_acceptance, type: String
    field :redirect_home, type: String
    field :choose_and_pay_label, type: String
    field :membership_count, type: Integer

    enablable.each do |x|
      field :"enable_#{x}", type: Mongoid::Boolean
    end

    %w[enable_supporters clear_up_optionships anonymise_supporters democratic_threshold require_reason_proposer require_reason_supporter demand_payment hide_members_on_application_form hide_invitations listed hide_paid].each do |b|
      field b.to_sym, type: Mongoid::Boolean
    end
  end

  class_methods do
    def privacies
      { 'Anyone with the link can join' => 'open', 'People must apply to join' => 'closed', 'Invitation-only' => 'secret' }
    end

    def enablable
      %w[contributions teams timetables rotas shift_worth inventory budget partial_payments]
    end

    def admin_fields
      h = {
        name: :text,
        slug: :slug,
        location: :text,
        image: :image,
        intro_for_members: :wysiwyg,
        welcome_email: :wysiwyg,
        fixed_threshold: :number,
        member_limit: :number,
        proposing_delay: :number,
        require_reason_proposer: :check_box,
        require_reason_supporter: :check_box,
        hide_invitations: :check_box,
        processed_via_dandelion: :number,
        stripe_pk: :text,
        stripe_sk: :text,
        stripe_endpoint_secret: :text,
        coinbase_api_key: :text,
        coinbase_webhook_secret: :text,
        balance: :number,
        democratic_threshold: :check_box,
        privacy: :select,
        intro_for_non_members: :wysiwyg,
        application_questions: :text_area,
        joining_questions: :text_area,
        enable_supporters: :check_box,
        anonymise_supporters: :check_box,
        clear_up_optionships: :check_box,
        demand_payment: :check_box,
        hide_members_on_application_form: :check_box,
        listed: :check_box,
        paypal_email: :text,
        redirect_on_acceptance: :text,
        currency: :select,
        account_id: :lookup,
        memberships: :collection,
        mapplications: :collection,
        spends: :collection,
        rotas: :collection,
        teams: :collection
      }
      h.merge(enablable.to_h do |x|
                [:"enable_#{x}", :check_box]
              end)
    end

    def human_attribute_name(attr, options = {})
      {
        slug: 'URL',
        intro_for_non_members: 'Intro for non-members',
        paypal_email: 'PayPal email',
        fixed_threshold: 'Magic number',
        democratic_threshold: 'Allow all gathering members to suggest a magic number, and use the median',
        require_reason_proposer: 'Proposers must provide a reason',
        require_reason_supporter: 'Supporters must provide a reason',
        demand_payment: 'Members must make a payment to access gathering content',
        hide_members_on_application_form: "Don't show existing members on the application form",
        invitations_granted: 'People may invite this many others by default',
        hide_invitations: 'Make the number of invitations granted visible to admins only',
        clear_up_optionships: 'Periodically remove people from unpaid options',
        enable_contributions: 'Enable Choose & Pay',
        stripe_endpoint_secret: 'Stripe endpoint secret',
        stripe_pk: 'Stripe public key',
        stripe_sk: 'Stripe secret key',
        coinbase_api_key: 'Coinbase Commerce API key',
        coinbase_webhook_secret: 'Coinbase Commerce webhook secret',
        evm_address: 'EVM address',
        privacy: 'Access',
        listed: 'List this gathering publicly',
        enable_rotas: 'Enable shifts',
        hide_paid: 'Hide financial columns in member list'
      }[attr.to_sym] || super
    end

    def new_hints
      {
        slug: 'Lowercase letters, numbers and dashes only (no spaces)',
        application_questions: 'Questions to ask applicants. One question per line.',
        joining_questions: 'Questions to ask people joining the gathering. One question per line.',
        currency: 'This cannot be changed, choose wisely',
        fixed_threshold: 'Automatically accept applications with this number of proposers + supporters (with at least one proposer)',
        proposing_delay: 'Accept proposers on applications only once the application is this many hours old',
        stripe_pk: '<code>Developers</code> > <code>API keys</code> > <code>Publishable key</code>. Starts <code>pk_live_</code>',
        stripe_sk: '<code>Developers</code> > <code>API keys</code> > <code>Secret key</code>. Starts <code>sk_live_</code>',
        stripe_endpoint_secret: '<code>Developers</code> > <code>Webhooks</code> > <code>Signing secret</code>. Starts <code>whsec_</code>',
        coinbase_api_key: '<code>Settings</code> > <code>API keys</code>',
        coinbase_webhook_secret: '<code>Settings</code> > <code>Webhook subscriptions</code> > <code>Show shared secret</code>',
        redirect_on_acceptance: 'Experimental',
        enable_teams: 'Create Slack/Facebook-like channels to organise different aspects of the gathering',
        enable_timetables: 'Co-create unconference-style timetables of workshops and activities',
        enable_rotas: 'Allow people to sign up for shifts, for example cooking, washing or community care',
        enable_contributions: 'Allow people to select and pay for core costs, accommodation and transport',
        enable_inventory: 'Allow people to list useful items and take responsibility for bringing them',
        enable_budget: "Show a live and transparent budget of the gathering's finances",
        enable_partial_payments: 'Allow people to pay just a part of any outstanding payment requests',
        enable_shift_worth: 'Show the points value of shifts',
        demand_payment: 'Require members to make a payment before accessing features like teams or timetables',
        clear_up_optionships: 'Remove people from any unpaid tiers, accommodation and transport options every hour',
        hide_paid: 'Hides the Requested contribution/Paid columns in the member list from non-admins'
      }
    end

    def edit_hints
      {}.merge(new_hints)
    end
  end
end
