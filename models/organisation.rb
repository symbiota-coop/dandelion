class Organisation
  include Mongoid::Document
  include Mongoid::Timestamps
  include Geocoder::Model::Mongoid
  extend Dragonfly::Model

  belongs_to :account, index: true

  field :name, type: String
  field :slug, type: String
  field :website, type: String
  field :reply_to, type: String
  field :intro_text, type: String
  field :telegram_group, type: String
  field :image_uid, type: String
  field :google_analytics_id, type: String
  field :facebook_pixel_id, type: String
  field :stripe_client_id, type: String
  field :stripe_endpoint_secret, type: String
  field :stripe_pk, type: String
  field :stripe_sk, type: String
  field :coinbase_api_key, type: String
  field :coinbase_webhook_secret, type: String
  field :gocardless_access_token, type: String
  field :gocardless_endpoint_secret, type: String
  field :gocardless_filter, type: String
  field :patreon_api_key, type: String
  field :mailgun_api_key, type: String
  field :mailgun_domain, type: String
  field :mailgun_region, type: String
  field :mailgun_sto, type: Boolean
  field :location, type: String
  field :coordinates, type: Array
  field :collect_location, type: Boolean
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
  field :auto_comment_sending, type: Boolean
  field :affiliate_credit_percentage, type: Integer
  field :affiliate_intro, type: String
  field :affiliate_share_image_url, type: String
  field :hidden, type: Boolean
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
  field :paid_up, type: Boolean
  field :send_ticket_emails_from_organisation, type: Boolean
  field :show_sign_in_link_in_ticket_emails, type: Boolean
  field :show_ticketholder_link_in_ticket_emails, type: Boolean
  field :ticket_email_greeting, type: String
  field :recording_email_greeting, type: String
  field :feedback_email_body, type: String
  field :verified, type: Boolean
  field :can_set_contribution, type: Boolean
  field :contribution_not_required, type: Boolean
  field :contribution_requested_per_event_gbp, type: Float
  field :contribution_offset_gbp, type: Float
  field :paid_up_fraction, type: Float
  field :ical_full, type: Boolean
  field :allow_purchase_url, type: Boolean
  field :change_select_tickets_title, type: Boolean
  field :event_image_required_height, type: Integer
  field :event_image_required_width, type: Integer
  field :restrict_cohosting, type: Boolean
  field :psychedelic, type: Boolean
  field :hide_few_left, type: Boolean
  field :sync_stripe, type: Boolean
  field :fixed_fee, type: Boolean
  field :terms_and_conditions_url, type: String
  field :terms_and_conditions, type: String
  field :terms_and_conditions_check_box, type: Boolean
  field :require_organiser_or_revenue_sharer, type: Boolean
  field :oc_slug, type: String
  field :hide_ticket_revenue, type: Boolean

  field :tokens, type: Float
  index({ tokens: 1 })
  def calculate_tokens
    Order.and(:event_id.in => events.pluck(:id), :value.ne => nil, :currency.in => MAJOR_CURRENCIES).sum { |o| Math.sqrt(Money.new(o.value * 100, o.currency).exchange_to('GBP').cents) } +
      organisation_contributions.and(:amount.ne => nil, :currency.in => MAJOR_CURRENCIES).sum { |p| Math.sqrt(Money.new(p.amount * 100, p.currency).exchange_to('GBP').cents) }
  end

  def self.admin_fields
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
      verified: :check_box,
      allow_purchase_url: :check_box,
      contribution_not_required: :check_box,
      contribution_requested_per_event_gbp: :number,
      contribution_offset_gbp: :number,
      paid_up_fraction: :number,
      event_image_required_height: :number,
      event_image_required_width: :number,
      psychedelic: :check_box,
      terms_and_conditions_url: :url,
      terms_and_conditions: :text_area,
      terms_and_conditions_check_box: :check_box
    }
  end

  def self.spring_clean
    fields = %i[image_uid]
    ignore = %i[organisationships notifications_as_notifiable]
    Organisation.all.each do |organisation|
      next unless Organisation.reflect_on_all_associations(:has_many).all? do |assoc|
        organisation.send(assoc.name).count == 0 || ignore.include?(assoc.name)
      end && fields.all? { |f| organisation.send(f).blank? } && organisation.created_at < 1.month.ago

      puts organisation.name
      organisation.destroy
    end
  end

  has_many :stripe_charges, dependent: :destroy
  has_many :stripe_transactions, dependent: :destroy

  has_many :discount_codes, class_name: 'DiscountCode', as: :codeable, dependent: :destroy

  has_many :organisation_edges_as_source, class_name: 'OrganisationEdge', inverse_of: :source, dependent: :destroy
  has_many :organisation_edges_as_sink, class_name: 'OrganisationEdge', inverse_of: :sink, dependent: :destroy

  def self.currencies
    CURRENCY_OPTIONS
  end

  def banned_emails_a
    banned_emails ? banned_emails.split("\n").map(&:strip) : []
  end

  def self.new_hints
    {
      slug: 'Lowercase letters, numbers and dashes only (no spaces)',
      image: 'Square images look best',
      stripe_pk: '<code>Developers</code> > <code>API keys</code> > <code>Publishable key</code>. Starts <code>pk_live_</code>',
      stripe_sk: '<code>Developers</code> > <code>API keys</code> > <code>Secret key</code>. Starts <code>sk_live_</code>',
      stripe_endpoint_secret: '<code>Developers</code> > <code>Webhooks</code> > <code>Signing secret</code>. Starts <code>whsec_</code>',
      stripe_client_id: 'Optional, used for automated revenue sharing. <code>Settings</code> > <code>Connect</code> > <code>Live mode client ID</code>. Starts <code>ca_</code>',
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
      hide_ticket_revenue: 'Hide ticket revenue in event stats'
    }
  end

  def self.edit_hints
    {}.merge(new_hints)
  end

  def self.marker_color
    '#FF5241'
  end

  def self.marker_icon
    'bi bi-flag-fill'
  end

  has_many :notifications_as_notifiable, as: :notifiable, dependent: :destroy, class_name: 'Notification', inverse_of: :notifiable
  has_many :notifications_as_circle, as: :circle, dependent: :destroy, class_name: 'Notification', inverse_of: :circle
  after_create do
    notifications_as_notifiable.create! circle: account, type: 'created_organisation'
  end

  # Geocoder
  geocoded_by :location
  def lat
    coordinates[1] if coordinates
  end

  def lng
    coordinates[0] if coordinates
  end
  after_validation do
    if location_changed?
      if location
        geocode || (self.coordinates = nil)
      else
        self.coordinates = nil
      end
    end
  end

  after_create do
    organisationships.create account: account, admin: true, receive_feedback: true
    if (dandelion = Organisation.find_by(slug: 'dandelion'))
      dandelion.organisationships.create account: account
    end
  end

  validates_presence_of :name, :slug, :currency
  validates_uniqueness_of :slug
  validates_format_of :slug, with: /\A[a-z0-9-]+\z/
  validates_format_of :stripe_sk, with: /\A[a-z0-9_]+\z/i, allow_nil: true
  validates_format_of :stripe_pk, with: /\A[a-z0-9_]+\z/i, allow_nil: true

  has_many :events, dependent: :nullify
  def cohosted_events
    Event.and(:id.in => cohostships.pluck(:event_id))
  end

  def events_including_cohosted
    Event.and(:id.in => events.pluck(:id) + cohostships.pluck(:event_id))
  end

  def events_for_search(draft: false, secret: false, include_all_local_group_events: false)
    e = Event.and(:id.in =>
        events.and(local_group_id: nil).pluck(:id) +
        events.and(:local_group_id.ne => nil, :draft => true).pluck(:id) +
        (include_all_local_group_events ? events.and(:local_group_id.ne => nil).pluck(:id) : events.and(:local_group_id.ne => nil, :include_in_parent => true).pluck(:id)) +
        cohostships.pluck(:event_id))
    e = e.live unless draft
    e = e.public unless secret
    e
  end

  def featured_events
    events_for_search.future_and_current_featured.and(:draft.ne => true).and(:image_uid.ne => nil).and(featured: true).limit(20).reject(&:sold_out?)
  end

  has_many :carousels, dependent: :destroy

  has_many :organisation_contributions, dependent: :destroy
  def contributable_events
    events.and(:draft.ne => true, :id.in =>
      Order.complete.and(:value.gt => 0, :event_id.in => events.pluck(:id)).pluck(:event_id) +
      events.and(:id.nin => TicketType.pluck(:event_id)).pluck(:id))
  end

  def self.contribution_requested_per_event_gbp
    20
  end

  def contribution_requested
    c = Money.new((-1 * (contribution_offset_gbp || 0) * 100) || 0, 'GBP')
    contributable_events.each do |event|
      c += event.contribution_gbp
    end
    c.exchange_to(MAJOR_CURRENCIES.include?(currency) ? currency : ENV['DEFAULT_CURRENCY'])
  end

  def contribution_paid
    s = Money.new(0, 'GBP')
    organisation_contributions.and(payment_completed: true).each do |organisation_contribution|
      s += Money.new(organisation_contribution.amount * 100, organisation_contribution.currency)
    end
    s.exchange_to(MAJOR_CURRENCIES.include?(currency) ? currency : ENV['DEFAULT_CURRENCY'])
  end

  def self.paid_up_fraction
    0.8
  end

  def contribution_threshold
    Money.new((contribution_requested_per_event_gbp || Organisation.contribution_requested_per_event_gbp) * 100, 'GBP')
  end

  def update_paid_up
    update_attribute(:paid_up, nil)
    begin
      update_attribute(:paid_up, contribution_not_required? || contribution_requested < contribution_threshold || contributable_events.count == 1 || contribution_paid >= (paid_up_fraction || Organisation.paid_up_fraction) * contribution_requested)
    rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
      update_attribute(:paid_up, true)
    end
  end

  has_many :cohostships, dependent: :destroy
  has_many :activities, dependent: :destroy
  has_many :organisationships, dependent: :destroy
  has_many :pmails, dependent: :destroy
  has_many :pmail_tests, dependent: :destroy
  def news
    pmails.and(mailable: nil, monthly_donors: nil, facilitators: nil).and(:sent_at.ne => nil).order('sent_at desc')
  end
  has_many :attachments, dependent: :destroy
  has_many :local_groups, dependent: :destroy
  has_many :organisation_tiers, dependent: :destroy

  has_many :orders_as_affiliate, class_name: 'Order', as: :affiliate, dependent: :nullify
  def orders
    Order.and(:event_id.in => events.pluck(:id))
  end

  def event_feedbacks
    EventFeedback.and(:event_id.in => events.pluck(:id))
  end

  def unscoped_event_feedbacks
    EventFeedback.unscoped.and(:event_id.in => events.pluck(:id))
  end

  def event_tags
    EventTag.and(:id.in => EventTagship.and(:event_id.in => events.pluck(:id)).pluck(:event_tag_id))
  end

  def activity_tags
    ActivityTag.and(:id.in => ActivityTagship.and(:activity_id.in => activities.pluck(:id)).pluck(:activity_tag_id))
  end

  dragonfly_accessor :image
  before_validation do
    if image
      begin
        if %w[jpeg png gif pam].include?(image.format)
          image.name = "#{SecureRandom.uuid}.#{image.format}"
        else
          errors.add(:image, 'must be an image')
        end
      rescue StandardError
        self.image = nil
        errors.add(:image, 'must be an image')
      end
    end
  end

  def ticket_email_greeting_default
    '<p>Hi [firstname],</p>
<p>Thanks for booking onto [event_name], [event_when] [at_event_location_if_not_online]. Your [tickets_are] attached.</p>'
  end

  def recording_email_greeting_default
    '<p>Hi [firstname],</p>
<p>Thanks for purchasing the recording of [event_name], [event_when] [at_event_location_if_not_online].</p>'
  end

  def feedback_email_body_default
    '<p>Hi [firstname],</p>
<p>Thanks for attending [event_name].</p>
<p>Would you take a minute to <a href="[feedback_url]">visit this page and give us feedback on the event</a>, so that we can keep improving?</p>
<p>With thanks,<br>[organisation_name]</p>'
  end

  before_validation do
    self.currency = 'GBP' unless currency
    self.ticket_email_greeting = ticket_email_greeting_default unless ticket_email_greeting
    self.recording_email_greeting = recording_email_greeting_default unless recording_email_greeting
    self.feedback_email_body = feedback_email_body_default unless feedback_email_body
    errors.add(:affiliate_credit_percentage, 'must be between 1 and 100') if affiliate_credit_percentage && (affiliate_credit_percentage < 1 || affiliate_credit_percentage > 100)

    errors.add(:mailgun_domain, 'must not be a sandbox domain') if mailgun_domain && mailgun_domain.starts_with?('sandbox') && mailgun_domain.ends_with?('mailgun.org')

    errors.add(:mailgun_domain, 'must be provided if other Mailgun details have been provided') if (mailgun_api_key || mailgun_region) && !mailgun_domain
    errors.add(:mailgun_api_key, 'must be provided if other Mailgun details have been provided') if (mailgun_domain || mailgun_region) && !mailgun_api_key
    errors.add(:mailgun_region, 'must be provided if other Mailgun details have been provided') if (mailgun_domain || mailgun_api_key) && !mailgun_region

    errors.add(:event_image_required_width, 'must be greater than 0') if event_image_required_width && event_image_required_width <= 0
    errors.add(:event_image_required_height, 'must be greater than 0') if event_image_required_height && event_image_required_height <= 0

    if Padrino.env == :production && account && !account.admin?
      errors.add(:stripe_sk, 'must start with sk_live_') if stripe_sk && !stripe_sk.starts_with?('sk_live_')
      errors.add(:stripe_pk, 'must start with pk_live_') if stripe_pk && !stripe_pk.starts_with?('pk_live_')
    end
    errors.add(:stripe_sk, 'must be present if Stripe public key is present') if stripe_pk && !stripe_sk
  end

  after_save :create_stripe_webhook_if_necessary, if: :stripe_sk
  def create_stripe_webhook_if_necessary
    return unless Padrino.env == :production

    Stripe.api_key = stripe_sk
    Stripe.api_version = '2020-08-27'

    webhooks = []
    has_more = true
    starting_after = nil
    while has_more
      w = Stripe::WebhookEndpoint.list({ limit: 100, starting_after: starting_after })
      has_more = w['has_more']
      unless w['data'].empty?
        webhooks += w['data']
        starting_after = w['data'].last['id']
      end
    end

    return if webhooks.find { |w| w['url'] == "#{ENV['BASE_URI']}/o/#{slug}/stripe_webhook" && w['enabled_events'].include?('checkout.session.completed') }

    w = Stripe::WebhookEndpoint.create({
                                         url: "#{ENV['BASE_URI']}/o/#{slug}/stripe_webhook",
                                         enabled_events: [
                                           'checkout.session.completed'
                                         ]
                                       })
    update_attribute(:stripe_endpoint_secret, w['secret'])
  rescue Stripe::AuthenticationError
    update_attribute(:stripe_sk, nil)
    update_attribute(:stripe_pk, nil)
  end

  def import_from_csv(csv)
    CSV.parse(csv, headers: true, header_converters: [:downcase, :symbol]).each do |row|
      email = row[:email]
      account_hash = { name: row[:name], email: row[:email], password: Account.generate_password }
      account = Account.new(account_hash) unless (account = Account.find_by(email: email.downcase))
      begin
        if account.persisted?
          account.update_attributes!(account_hash.map do |k, v|
                                       [k, v] if v
                                     end.compact.to_h)
        else
          account.save!
        end
        organisationships.create account: account, skip_welcome: row[:skip_welcome]
      rescue StandardError
        next
      end
    end
  end
  handle_asynchronously :import_from_csv

  def members
    Account.and(organisation_ids_cache: id)
  end

  def subscribed_accounts
    subscribed_members.and(:unsubscribed.ne => true)
  end

  def subscribed_members
    Account.and(:id.in => organisationships.and(:unsubscribed.ne => true).pluck(:account_id))
  end

  def unsubscribed_members
    Account.and(:id.in => organisationships.and(unsubscribed: true).pluck(:account_id))
  end

  def admins
    Account.and(:id.in => organisationships.and(admin: true).pluck(:account_id))
  end

  def admins_receiving_feedback
    Account.and(:id.in => organisationships.and(admin: true).and(receive_feedback: true).pluck(:account_id))
  end

  def revenue_sharers
    Account.and(:id.in => organisationships.and(:stripe_connect_json.ne => nil).pluck(:account_id))
  end

  def monthly_donors
    Account.and(:id.in => organisationships.and(:monthly_donation_method.ne => nil).pluck(:account_id))
  end

  def subscribed_monthly_donors
    Account.and(:id.in => organisationships.and(:monthly_donation_method.ne => nil, :unsubscribed.ne => true).pluck(:account_id))
  end

  def not_monthly_donors
    Account.and(:id.in => organisationships.and(monthly_donation_method: nil).pluck(:account_id))
  end

  def subscribed_not_monthly_donors
    Account.and(:id.in => organisationships.and(:monthly_donation_method => nil, :unsubscribed.ne => true).pluck(:account_id))
  end

  def facilitators
    Account.and(:id.in =>
        EventFacilitation.and(:event_id.in => events.future.pluck(:id)).pluck(:account_id) +
        Activityship.and(:activity_id.in => activities.pluck(:id), :admin => true).pluck(:account_id))
  end

  def self.admin?(organisation, account)
    account && organisation &&
      (
        account.admin? ||
        organisation.organisationships.find_by(account: account, admin: true)
      )
  end

  def self.assistant?(organisation, account)
    account && organisation && (Organisation.admin?(organisation, account) or organisation.local_groups.any? { |local_group| LocalGroup.admin?(local_group, account) } or organisation.activities.any? { |activity| Activity.admin?(activity, account) })
  end

  def self.monthly_donor_plus?(organisation, account)
    account && organisation && (Organisation.admin?(organisation, account) || organisation.organisationships.find_by(:account => account, :monthly_donation_method.ne => nil))
  end

  def self.mailgun_regions
    ['', 'EU', 'US']
  end

  def stripe_webhooks
    Stripe.api_key = stripe_sk
    Stripe.api_version = '2020-08-27'
    webhooks = []
    has_more = true
    starting_after = nil
    while has_more
      w = Stripe::WebhookEndpoint.list({ limit: 100, starting_after: starting_after })
      webhooks += w.data
      has_more = w.has_more
      starting_after = w.data.last.id
    end
    webhooks
  end

  def self.human_attribute_name(attr, options = {})
    {
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

  def payment_method?
    stripe_pk || coinbase_api_key || evm_address || oc_slug
  end

  def sync_with_gocardless
    organisationships.and(monthly_donation_method: 'GoCardless').set(
      monthly_donation_method: nil,
      monthly_donation_amount: nil,
      monthly_donation_currency: nil,
      monthly_donation_start_date: nil
    )

    client = GoCardlessPro::Client.new(access_token: gocardless_access_token)

    list = client.subscriptions.list(params: { status: 'active' })
    subscriptions = list.records
    after = list.after
    while after
      list = client.subscriptions.list(params: { status: 'active', after: after })
      subscriptions += list.records
      after = list.after
    end

    subscriptions.each do |subscription|
      gocardless_subscribe(subscription: subscription)
    end
  end

  def gocardless_subscribe(subscription: nil, subscription_id: nil)
    client = GoCardlessPro::Client.new(access_token: gocardless_access_token)

    begin
      subscription = client.subscriptions.get(subscription_id) if subscription_id
    rescue GoCardlessPro::InvalidApiUsageError # to handle test webhooks
      return
    end
    return unless subscription.status == 'active'

    return if gocardless_filter && !subscription.name.include?(gocardless_filter)

    mandate = client.mandates.get(subscription.links.mandate)
    customer = client.customers.get(mandate.links.customer)

    name = "#{customer.given_name} #{customer.family_name}"
    email = customer.email
    postcode = customer.postal_code
    amount = subscription.amount
    currency = subscription.currency
    start_date = subscription.start_date
    puts "#{name} #{email} #{amount} #{currency} #{start_date}"

    account = Account.find_by(email: email.downcase) || Account.create(name: name, email: email)
    organisationship = organisationships.find_by(account: account) || organisationships.create(account: account)

    organisationship.monthly_donation_method = 'GoCardless'
    organisationship.monthly_donation_amount = amount.to_f / 100
    organisationship.monthly_donation_currency = currency
    organisationship.monthly_donation_start_date = start_date
    organisationship.monthly_donation_postcode = postcode
    organisationship.save
  end

  def sync_with_patreon
    organisationships.and(monthly_donation_method: 'Patreon').set(
      monthly_donation_method: nil,
      monthly_donation_amount: nil,
      monthly_donation_currency: nil,
      monthly_donation_start_date: nil
    )

    api_client = Patreon::API.new(patreon_api_key)

    # Get the campaign ID
    campaign_response = api_client.fetch_campaign
    campaign_id = campaign_response.data[0].id

    # Fetch all pledges
    all_pledges = []
    cursor = nil
    loop do
      page_response = api_client.fetch_page_of_pledges(campaign_id, { count: 25, cursor: cursor })
      all_pledges += page_response.data
      next_page_link = page_response.links[page_response.data]['next']
      break unless next_page_link

      parsed_query = CGI.parse(next_page_link)
      cursor = parsed_query['page[cursor]'][0]
    end

    all_pledges.each do |pledge|
      next unless pledge.declined_since.nil?

      name = pledge.patron.full_name
      email = pledge.patron.email
      amount = pledge.amount_cents
      currency = pledge.currency
      start_date = pledge.created_at

      puts "#{name} #{email} #{amount} #{currency} #{start_date}"
      account = Account.find_by(email: email.downcase) || Account.create(name: name, email: email)
      organisationship = organisationships.find_by(account: account) || organisationships.create(account: account)

      organisationship.monthly_donation_method = 'Patreon'
      organisationship.monthly_donation_amount = amount.to_f / 100
      organisationship.monthly_donation_currency = currency
      organisationship.monthly_donation_start_date = start_date
      organisationship.save
    end
  end

  def self.evm_transactions(evm_address)
    transactions = []
    agent = Mechanize.new

    # Blockscout v1
    [
      "https://explorer.celo.org/address/#{evm_address}/token-transfers?type=JSON"
    ].compact.each do |url|
      puts url
      page = begin; agent.get(url); rescue Mechanize::ResponseCodeError; end
      next unless page

      j = JSON.parse(page.body)
      j['items'].each do |item|
        h = Nokogiri::HTML(item)

        to = h.search('[data-test=token_transfer] [data-address-hash]')[1].attr('data-address-hash').downcase
        next unless to == evm_address.downcase

        token_address = h.search('[data-test=token_link]')[0].attr('href').split('/').last
        next unless token_address

        token_find = Token.by_contract_address.find { |k, _v| k.downcase == token_address.downcase }
        next unless token_find

        token = token_find[1]
        next unless token

        amount = h.search('[data-test=token_transfer] > span')[1].text.split(' ').first.gsub(',', '')
        next unless amount

        puts [token, amount]
        transactions << [token, amount]
      end
    end

    # Blockscout v2
    [
      "https://optimism.blockscout.com/api/v2/addresses/#{evm_address}/token-transfers",
      "https://gnosis.blockscout.com/api/v2/addresses/#{evm_address}/token-transfers",
      "https://base.blockscout.com/api/v2/addresses/#{evm_address}/token-transfers"
    ].each do |url|
      puts url
      page = begin; agent.get(url); rescue Mechanize::ResponseCodeError; end
      next unless page

      j = JSON.parse(page.body)
      j['items'].each do |item|
        to = item['to']['hash']
        next unless to.downcase == evm_address.downcase

        token_address = item['token']['address']
        next unless token_address

        token_find = Token.by_contract_address.find { |k, _v| k.downcase == token_address.downcase }
        next unless token_find

        token = token_find[1]
        next unless token

        amount = item['total']['value'].to_f / (10**item['total']['decimals'].to_i)
        next unless amount

        puts [token, amount]
        transactions << [token, amount]
      end
    end

    transactions
  end

  def evm_transactions
    Organisation.evm_transactions(evm_address)
  end

  def check_evm_account
    evm_transactions.each do |token, amount|
      if (@order = Order.find_by(:payment_completed.ne => true, :currency => token, :evm_value => amount))
        @order.payment_completed!
        @order.send_tickets
        @order.create_order_notification
      elsif (@order = Order.deleted.find_by(:payment_completed.ne => true, :currency => token, :evm_value => amount))
        begin
          @order.restore_and_complete
          # raise Order::Restored
        rescue StandardError => e
          Airbrake.notify(e, order: @order)
        end
      end
    end
  end

  def send_followers_csv(account)
    csv = CSV.generate do |csv|
      csv << %w[name email unsubscribed monthly_donation_method monthly_donation_amount monthly_donation_currency monthly_donation_start_date]
      organisationships.each do |organisationship|
        csv << [
          organisationship.account.name,
          Organisation.admin?(self, account) ? organisationship.account.email : '',
          (1 if organisationship.unsubscribed),
          organisationship.monthly_donation_method,
          organisationship.monthly_donation_amount,
          organisationship.monthly_donation_currency,
          organisationship.monthly_donation_start_date
        ]
      end
    end

    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    content = ERB.new(File.read(Padrino.root('app/views/emails/csv.erb'))).result(binding)
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject 'Dandelion CSV export'
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    file = Tempfile.new
    file.write(csv)
    file.rewind
    batch_message.add_attachment(file.path, 'followers.csv')

    [account].each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
    file.close
    file.unlink
  end
  handle_asynchronously :send_followers_csv
end
