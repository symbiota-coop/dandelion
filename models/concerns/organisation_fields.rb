module OrganisationFields
  extend ActiveSupport::Concern

  included do
    dragonfly_accessor :image

    field :name, type: String
    field :slug, type: String
    field :website, type: String
    field :reply_to, type: String
    field :intro_text, type: String
    field :telegram_group, type: String
    field :image_uid, type: String
    field :google_analytics_id, type: String
    field :facebook_pixel_id, type: String
    field :stripe_connect_json, type: String
    field :stripe_account_json, type: String
    field :stripe_client_id, type: String
    field :stripe_endpoint_secret, type: String
    field :stripe_pk, type: String
    field :stripe_sk, type: String
    field :stripe_customer_id, type: String
    field :card_last4, type: String
    field :coinbase_api_key, type: String
    field :coinbase_webhook_secret, type: String
    field :gocardless_access_token, type: String
    field :gocardless_endpoint_secret, type: String
    field :gocardless_filter, type: String
    field :patreon_api_key, type: String
    field :mailgun_api_key, type: String
    field :mailgun_domain, type: String
    field :mailgun_region, type: String
    field :mailgun_sto, type: Mongoid::Boolean
    field :location, type: String
    field :coordinates, type: Array
    field :collect_location, type: Mongoid::Boolean
    field :post_url, type: String
    field :extra_info_for_ticket_email, type: String
    field :event_footer, type: String
    field :minimal_head, type: String
    field :followers_count, type: Integer
    field :subscribed_accounts_count, type: Integer
    field :monthly_donor_affiliate_reward, type: Integer
    field :monthly_donors_count, type: Integer
    field :monthly_donations_count, type: String
    field :currency, type: String
    field :auto_comment_sending, type: Mongoid::Boolean
    field :affiliate_credit_percentage, type: Integer
    field :affiliate_intro, type: String
    field :affiliate_share_image_url, type: String
    field :hidden, type: Mongoid::Boolean
    field :welcome_from, type: String
    field :welcome_subject, type: String
    field :welcome_body, type: String
    field :monthly_donation_welcome_from, type: String
    field :monthly_donation_welcome_subject, type: String
    field :monthly_donation_welcome_body, type: String
    field :evm_address, type: String
    field :add_a_donation_to, type: String
    field :donation_text, type: String
    field :become_a_member_url, type: String
    field :events_banner, type: String
    field :banned_emails, type: String
    field :paid_up, type: Mongoid::Boolean
    field :send_ticket_emails_from_organisation, type: Mongoid::Boolean
    field :show_sign_in_link_in_ticket_emails, type: Mongoid::Boolean
    field :show_ticketholder_link_in_ticket_emails, type: Mongoid::Boolean
    field :ticket_email_greeting, type: String
    field :recording_email_greeting, type: String
    field :feedback_email_body, type: String
    field :experimental, type: Mongoid::Boolean
    field :unsanitized_ok, type: Mongoid::Boolean
    field :can_set_contribution, type: Mongoid::Boolean
    field :contribution_not_required, type: Mongoid::Boolean
    field :contribution_requested_gbp_cache, type: Float
    field :contribution_paid_gbp_cache, type: Float
    field :contribution_requested_per_event_gbp, type: Float
    field :contribution_offset_gbp, type: Float
    field :ical_full, type: Mongoid::Boolean
    field :allow_purchase_url, type: Mongoid::Boolean
    field :change_select_tickets_title, type: Mongoid::Boolean
    field :event_image_required_height, type: Integer
    field :event_image_required_width, type: Integer
    field :restrict_cohosting, type: Mongoid::Boolean
    field :psychedelic, type: Mongoid::Boolean
    field :hide_few_left, type: Mongoid::Boolean
    field :sync_stripe, type: Mongoid::Boolean
    field :fixed_fee, type: Mongoid::Boolean
    field :terms_and_conditions_url, type: String
    field :terms_and_conditions, type: String
    field :terms_and_conditions_check_box, type: Mongoid::Boolean
    field :require_organiser_or_revenue_sharer, type: Mongoid::Boolean
    field :oc_slug, type: String
    field :hide_ticket_revenue, type: Mongoid::Boolean
    field :allow_iframes, type: Mongoid::Boolean
    field :time_zone, type: String
    field :billing_address_collection, type: Mongoid::Boolean

    field :tokens, type: Float
    index({ tokens: 1 })
  end

  class_methods do
    def admin_fields
      {
        name: :text,
        slug: :slug,
        intro_text: :wysiwyg,
        website: :url,
        telegram_group: :url,
        reply_to: :text,
        image: :image,
        hidden: :check_box,
        paid_up: :check_box,
        google_analytics_id: :text,
        facebook_pixel_id: :text,
        stripe_connect_json: :text,
        stripe_account_json: :text,
        stripe_client_id: :text,
        stripe_endpoint_secret: :text,
        coinbase_api_key: :text,
        coinbase_webhook_secret: :text,
        stripe_pk: :text,
        stripe_sk: :text,
        gocardless_access_token: :text,
        gocardless_endpoint_secret: :text,
        gocardless_filter: :text,
        patreon_api_key: :text,
        mailgun_api_key: :text,
        mailgun_domain: :text,
        mailgun_region: :select,
        mailgun_sto: :check_box,
        oc_slug: :text,
        minimal_head: :text,
        donation_text: :text,
        add_a_donation_to: :text,
        become_a_member_url: :url,
        welcome_from: :text,
        welcome_subject: :text,
        welcome_body: :text_area,
        monthly_donation_welcome_from: :text,
        monthly_donation_welcome_subject: :text,
        monthly_donation_welcome_body: :text_area,
        extra_info_for_ticket_email: :wysiwyg,
        collect_location: :check_box,
        post_url: :url,
        event_footer: :wysiwyg,
        banned_emails: :text_area,
        experimental: :check_box,
        unsanitized_ok: :check_box,
        allow_purchase_url: :check_box,
        contribution_not_required: :check_box,
        contribution_requested_per_event_gbp: :number,
        contribution_offset_gbp: :number,
        event_image_required_height: :number,
        event_image_required_width: :number,
        psychedelic: :check_box,
        terms_and_conditions_url: :url,
        terms_and_conditions: :text_area,
        terms_and_conditions_check_box: :check_box,
        billing_address_collection: :check_box
      }
    end

    def human_attribute_name(attr, options = {})
      {
        name: 'Organisation name',
        slug: 'URL',
        intro_text: 'Intro text for organisation homepage',
        telegram_group: 'Telegram group/channel URL',
        extra_info_for_ticket_email: 'Extra info for ticket confirmation email',
        google_analytics_id: 'Google Analytics ID',
        facebook_pixel_id: 'Facebook Pixel ID',
        stripe_client_id: 'Stripe client ID',
        stripe_endpoint_secret: 'Stripe endpoint secret',
        stripe_pk: 'Stripe public key',
        stripe_sk: 'Stripe secret key',
        gocardless_access_token: 'GoCardless access token',
        coinbase_api_key: 'Coinbase Commerce API key',
        coinbase_webhook_secret: 'Coinbase Commerce webhook secret',
        patreon_api_key: 'Patreon API key',
        mailgun_api_key: 'Mailgun API key',
        evm_address: 'EVM address',
        collect_location: 'Ask for location of ticket buyers',
        reply_to: 'Reply address for ticket emails',
        minimal_head: 'Extra content for &lt;head&gt; when embedding events page',
        affiliate_share_image_url: 'Affiliate share image URL',
        welcome_from: 'Welcome email from',
        welcome_subject: 'Welcome email subject',
        welcome_body: 'Welcome email body',
        monthly_donation_welcome_from: 'Welcome email for new monthly donors from',
        monthly_donation_welcome_subject: 'Welcome email for new monthly donors subject',
        monthly_donation_welcome_body: 'Welcome email for new monthly donors body',
        auto_comment_sending: "Send comments in the Members' Area automatically",
        become_a_member_url: 'Become a Member URL',
        terms_and_conditions_url: 'Terms and Conditions URL',
        add_a_donation_to: 'Text above donation field',
        donation_text: 'Text below donation field',
        show_ticketholder_link_in_ticket_emails: 'Show link for people to provide details of ticketholders in ticket emails',
        event_image_required_width: 'Event image width',
        event_image_required_height: 'Event image height',
        restrict_cohosting: 'Restrict cohosting to admins',
        oc_slug: 'Open Collective slug'
      }[attr.to_sym] || super
    end

    def new_hints
      {
        slug: 'Lowercase letters, numbers and dashes only (no spaces)',
        image: 'Square images look best',
        stripe_pk: '<code>Developers</code> > <code>API keys</code> > <code>Publishable key</code>. Starts <code>pk_live_</code>',
        stripe_sk: '<code>Developers</code> > <code>API keys</code> > <code>Secret key</code>. Starts <code>sk_live_</code>',
        stripe_endpoint_secret: '<code>Developers</code> > <code>Webhooks</code> > <code>Signing secret</code>. Starts <code>whsec_</code>',
        stripe_client_id: 'Used for automated revenue sharing. <code>Settings</code> > <code>Connect</code> > <code>Live mode client ID</code>. Starts <code>ca_</code>',
        coinbase_api_key: '<code>Settings</code> > <code>API keys</code>',
        coinbase_webhook_secret: '<code>Settings</code> > <code>Webhook subscriptions</code> > <code>Show shared secret</code>',
        mailgun_api_key: '<code>Settings</code> > <code>API keys</code>',
        mailgun_domain: '<code>Sending</code> > <code>Domains</code> > <code>Add new domain</code>',
        affiliate_credit_percentage: 'Default affiliate credit percentage when creating an event',
        monthly_donor_affiliate_reward: 'When an existing monthly donor gets a friend to sign up via their affiliate link, credit of this amount is issued to both the existing monthly donor and the friend/new member.',
        add_a_donation_to: "Text to display above the 'Add a donation' field",
        donation_text: "Text to display below the 'Add a donation' field",
        send_ticket_emails_from_organisation: 'Requires image and reply address',
        gocardless_access_token: 'Registers people with active GoCardless subscriptions as monthly donors',
        patreon_api_key: 'Registers people with active Patreon subscriptions as monthly donors',
        become_a_member_url: 'Link to direct non-members to when they attempt to buy tickets to a members-only event',
        terms_and_conditions_url: "Link to the organisation's terms and conditions of sale",
        terms_and_conditions: 'Terms and conditions to be displayed on the ticket purchase page',
        terms_and_conditions_check_box: 'Require attendees to check a box to confirm they have read and agree to the terms and conditions',
        event_footer: 'Included at the end of all public event descriptions',
        banned_emails: 'One per line',
        event_image_required_width: 'Required width for event images in px',
        event_image_required_height: 'Required height for event images in px',
        evm_address: 'Ethereum-compatible wallet address for receiving tokens via EVM networks',
        restrict_cohosting: 'When checked, only admins can add the organisation as a co-host of events',
        oc_slug: 'Open Collective organisation slug',
        hide_ticket_revenue: 'Hide ticket revenue in event stats',
        collect_location: 'Request the location of ticket buyers at checkout'
      }
    end

    def edit_hints
      {}.merge(new_hints)
    end

    def mailgun_regions
      ['', 'EU', 'US']
    end
  end
end
