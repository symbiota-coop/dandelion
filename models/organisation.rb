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
  field :subscribed_accounts_count, type: Integer
  field :monthly_donor_affiliate_reward, type: Integer
  field :monthly_donors_count, type: Integer
  field :monthly_donations_count, type: String
  field :currency, type: String
  field :enable_discussion, type: Boolean
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
  field :seeds_username, type: String
  field :evm_address, type: String
  field :carousels, type: String
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
  field :contribution_not_required, type: Boolean
  field :contribution_requested_per_event_gbp, type: Integer
  field :ical_full, type: Boolean
  field :allow_purchase_url, type: Boolean
  field :change_select_tickets_title, type: Boolean
  field :event_image_required_height, type: Integer
  field :event_image_required_width, type: Integer
  field :allow_quick, type: Boolean
  field :restrict_cohosting, type: Boolean
  field :psychedelic, type: Boolean
  field :hide_few_left, type: Boolean
  field :google_drive_client_id, type: String
  field :google_drive_client_secret, type: String
  field :google_drive_refresh_token, type: String
  field :google_drive_scope, type: String
  field :google_sheets_key, type: String

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
      event_image_required_height: :number,
      event_image_required_width: :number,
      psychedelic: :check_box
    }
  end

  has_many :discount_codes, class_name: 'DiscountCode', as: :codeable, dependent: :destroy

  def self.currencies
    CURRENCIES_HASH
  end

  def banned_emails_a
    banned_emails ? banned_emails.split("\n").map(&:strip) : []
  end

  def self.new_hints
    {
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
      event_footer: 'Included at the end of all public event descriptions',
      carousels: "To create a carousel on your organisation's events page with the title X showing event tags a and b, type X: a, b",
      banned_emails: 'One per line',
      event_image_required_width: 'Required width for event images in px',
      event_image_required_height: 'Required height for event images in px',
      evm_address: 'Ethereum-compatible wallet address for receiving tokens via Gnosis Chain and Celo',
      seeds_username: 'SEEDS/Telos username for receiving SEEDS via Telos',
      restrict_cohosting: 'When checked, only admins can add the organisation as a co-host of events'
    }
  end

  def self.edit_hints
    {}.merge(new_hints)
  end

  def self.new_tips
    {
      slug: 'Lowercase letters, numbers and dashes only (no spaces)'
    }
  end

  def self.edit_tips
    {}.merge(new_tips)
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
    geocode || (self.coordinates = nil) if ENV['GOOGLE_MAPS_API_KEY']
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

  has_many :organisation_contributions, dependent: :destroy
  def contributable_events
    events.and(:id.in => Order.and(:value.gt => 0, :event_id.in => events.pluck(:id)).pluck(:event_id))
  end

  def self.contribution_requested_per_event_gbp
    15
  end

  def contribution_requested
    c = contributable_events.count
    Money.new(c * (contribution_requested_per_event_gbp || Organisation.contribution_requested_per_event_gbp) * 100, 'GBP').exchange_to(MAJOR_CURRENCIES.include?(currency) ? currency : ENV['DEFAULT_CURRENCY'])
  end

  def contribution_paid
    organisation_contributions.and(payment_completed: true).sum { |organisation_contribution| Money.new(organisation_contribution.amount * 100, organisation_contribution.currency) }
  end

  def update_paid_up
    update_attribute(:paid_up, nil)
    begin
      update_attribute(:paid_up, contribution_not_required? || contribution_requested.zero? || contributable_events.count == 1 || contribution_paid >= 0.5 * contribution_requested)
    rescue Money::Bank::UnknownRate
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

  has_many :posts, as: :commentable, dependent: :destroy
  has_many :subscriptions, as: :commentable, dependent: :destroy
  has_many :comments, as: :commentable, dependent: :destroy
  has_many :comment_reactions, as: :commentable, dependent: :destroy

  has_many :orders_as_affiliate, class_name: 'Order', as: :affiliate, dependent: :nullify
  def orders
    Order.and(:event_id.in => events.pluck(:id))
  end

  def event_feedbacks
    EventFeedback.and(:event_id.in => events.pluck(:id))
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
        errors.add(:image, 'must be an image') unless %w[jpeg png gif pam].include?(image.format)
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
  end

  def import_from_csv(csv)
    CSV.parse(csv, headers: true, header_converters: [:downcase, :symbol]).each do |row|
      email = row[:email]
      account_hash = { name: row[:name], email: row[:email], password: Account.generate_password }
      account = if (account = Account.find_by(email: email.downcase))
                  account
                else
                  Account.new(account_hash)
                end
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

  def discussers
    Account.and(:id.in => organisationships.and(:monthly_donation_method.ne => nil, :subscribed_discussion => true).pluck(:account_id))
  end

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
      seeds_username: 'SEEDS username',
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
      enable_discussion: "Enable discussion feature in the Members' Area",
      auto_comment_sending: "Send comments in the Members' Area automatically",
      become_a_member_url: 'Become a Member URL',
      add_a_donation_to: 'Text above donation field',
      donation_text: 'Text below donation field',
      show_ticketholder_link_in_ticket_emails: 'Show link for people to provide details of ticketholders in ticket emails',
      event_image_required_width: 'Event image width',
      event_image_required_height: 'Event image height',
      restrict_cohosting: 'Restrict cohosting to admins'
    }[attr.to_sym] || super
  end

  def payment_method?
    stripe_pk || coinbase_api_key || evm_address || seeds_username
  end

  def sync_with_gocardless
    organisationships.and(monthly_donation_method: 'GoCardless').set(
      monthly_donation_method: nil,
      monthly_donation_amount: nil,
      monthly_donation_currency: nil,
      monthly_donation_start_date: nil,
      monthly_donation_postcode: nil
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
      monthly_donation_start_date: nil,
      monthly_donation_postcode: nil
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

  def check_seeds_account
    agent = Mechanize.new
    agent.agent.http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    j = JSON.parse(agent.get("https://telos.caleos.io/v2/history/get_actions?account=#{seeds_username}").body)
    j['actions'].each do |action|
      next unless action['act'] && (data = action['act']['data'])
      next unless data['to'] == seeds_username && data['symbol'] == 'SEEDS' && data['amount'] && !data['memo'].blank? && (seeds_secret = data['memo'].split('SGP: ').last)

      puts "#{data['amount']} SEEDS: #{seeds_secret}"
      if (@order = Order.find_by(:payment_completed.ne => true, :seeds_secret => seeds_secret.downcase, :seeds_value => data['amount']))
        @order.set(payment_completed: true)
        @order.send_tickets
        @order.create_order_notification
      elsif (@order = Order.deleted.find_by(:payment_completed.ne => true, :seeds_secret => seeds_secret.downcase, :seeds_value => data['amount']))
        begin
          @order.restore_and_complete
          # raise Order::Restored
        rescue StandardError => e
          Airbrake.notify(e, order: @order)
        end
      end
    end
  end

  def check_evm_account
    agent = Mechanize.new
    [
      begin; JSON.parse(agent.get("https://blockscout.com/poa/xdai/address/#{evm_address}/token-transfers?type=JSON").body); rescue Mechanize::ResponseCodeError; end,
      begin; JSON.parse(agent.get("https://explorer.celo.org/address/#{evm_address}/token-transfers?type=JSON").body); rescue Mechanize::ResponseCodeError; end
    ].compact.each do |j|
      items = j['items']
      items.each do |item|
        puts h = Nokogiri::HTML(item)
        puts to = h.search('[data-test=token_transfer] [data-address-hash]')[1].attr('data-address-hash').downcase
        puts token = h.search('[data-test=token_link]').text.upcase
        next unless to == evm_address.downcase

        puts amount = h.search('[data-test=token_transfer] > span')[1].text.split(' ').first.gsub(',', '')

        if (@order = Order.find_by(:payment_completed.ne => true, :currency => token, :evm_value => amount))
          @order.set(payment_completed: true)
          @order.send_tickets
          @order.create_order_notification
        elsif (@order = Order.deleted.find_by(:payment_completed.ne => true, :evm_value => amount))
          begin
            @order.restore_and_complete
            # raise Order::Restored
          rescue StandardError => e
            Airbrake.notify(e, order: @order)
          end
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

    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], 'api.eu.mailgun.net'
    batch_message = Mailgun::BatchMessage.new(mg_client, 'notifications.dandelion.earth')

    content = ERB.new(File.read(Padrino.root('app/views/emails/csv.erb'))).result(binding)
    batch_message.from 'Dandelion <notifications@dandelion.earth>'
    batch_message.subject 'Dandelion CSV export'
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    file = Tempfile.new
    file.write(csv)
    file.rewind
    batch_message.add_attachment(file.path, 'followers.csv')

    [account].each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => (account.firstname || 'there'), 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
    file.close
    file.unlink
  end
  handle_asynchronously :send_followers_csv

  def transfer_events
    session = GoogleDrive::Session.from_config(OpenStruct.new(
                                                 client_id: google_drive_client_id,
                                                 client_secret: google_drive_client_secret,
                                                 refresh_token: google_drive_refresh_token,
                                                 scope: google_drive_scope.split(',')
                                               ))

    worksheet_name = 'Dandelion events'
    worksheet = session.spreadsheet_by_key(google_sheets_key).worksheets.find { |worksheet| worksheet.title == worksheet_name }
    rows = []

    event_ids = worksheet.instance_variable_get(:@session).sheets_service.get_spreadsheet_values(
      worksheet.spreadsheet.id,
      'Dandelion events!A2:A'
    ).values.flatten

    events.live.and(:id.nin => event_ids, :start_time.gte => '2020-06-01').each do |event|
      row = { id: event.id.to_s }
      rows << row
    end

    worksheet.instance_variable_get(:@session).sheets_service.append_spreadsheet_value(
      worksheet.spreadsheet.id,
      worksheet_name,
      Google::Apis::SheetsV4::ValueRange.new(values: rows.reverse.map(&:values)),
      value_input_option: 'USER_ENTERED'
    )

    # worksheet.insert_rows(worksheet.num_rows + 1, rows.reverse.map(&:values))
    # worksheet.save
  end

  def transfer_charges
    from = Date.today - 2
    to = Date.today - 1
    Stripe.api_key = stripe_sk
    Stripe.api_version = '2020-08-27'
    charges = Stripe::Charge.list(created: { gte: Time.utc(from.year, from.month, from.day).to_i, lt: Time.utc(to.year, to.month, to.day).to_i })

    session = GoogleDrive::Session.from_config(OpenStruct.new(
                                                 client_id: google_drive_client_id,
                                                 client_secret: google_drive_client_secret,
                                                 refresh_token: google_drive_refresh_token,
                                                 scope: google_drive_scope.split(',')
                                               ))

    worksheet_name = 'Stripe charges'
    worksheet = session.spreadsheet_by_key(google_sheets_key).worksheets.find { |worksheet| worksheet.title == worksheet_name }
    rows = []
    charges.auto_paging_each do |charge|
      row = {}
      %w[id amount application_fee application_fee_amount balance_transaction created currency customer description destination payment_intent].each do |f|
        row[f] = case f
                 when 'created'
                   Time.at(charge[f]).utc.strftime('%Y-%m-%d %H:%M:%S +0000')
                 else
                   charge[f]
                 end
      end
      %w[de_event_id de_order_id de_account_id de_donation_revenue de_ticket_revenue de_discounted_ticket_revenue de_percentage_discount de_percentage_discount_monthly_donor de_credit_applied].each do |f|
        row[f] = charge['metadata'][f]
      end
      puts row['created']
      rows << row
    end

    worksheet.instance_variable_get(:@session).sheets_service.append_spreadsheet_value(
      worksheet.spreadsheet.id,
      worksheet_name,
      Google::Apis::SheetsV4::ValueRange.new(values: rows.reverse.map(&:values)),
      value_input_option: 'USER_ENTERED'
    )

    # worksheet.insert_rows(worksheet.num_rows + 1, rows.reverse.map(&:values))
    # worksheet.save
  end

  def transfer_transactions
    from = Date.today - 2
    to = Date.today - 1
    Stripe.api_key = stripe_sk
    Stripe.api_version = '2020-08-27'

    run = Stripe::Reporting::ReportRun.create({
                                                report_type: 'balance_change_from_activity.itemized.1',
                                                parameters: {
                                                  interval_start: Time.utc(from.year, from.month, from.day).to_i,
                                                  interval_end: Time.utc(to.year, to.month, to.day).to_i
                                                }
                                              })

    until run.result
      sleep 5
      run = Stripe::Reporting::ReportRun.retrieve(run.id)
    end

    uri = URI(run.result.url)
    csv = nil
    Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      request = Net::HTTP::Get.new uri.request_uri
      request.basic_auth stripe_sk, ''
      response = http.request request
      csv = CSV.parse(response.body.encode('utf-8', invalid: :replace, undef: :replace, replace: '_'), headers: true, header_converters: :symbol)
    end

    session = GoogleDrive::Session.from_config(OpenStruct.new(
                                                 client_id: google_drive_client_id,
                                                 client_secret: google_drive_client_secret,
                                                 refresh_token: google_drive_refresh_token,
                                                 scope: google_drive_scope.split(',')
                                               ))

    worksheet_name = 'Stripe transactions'
    worksheet = session.spreadsheet_by_key(google_sheets_key).worksheets.find { |worksheet| worksheet.title == worksheet_name }
    rows = []
    csv.each do |row|
      row = row.to_hash
      %w[created_utc available_on_utc].each do |f|
        row[f.to_sym] = "#{row[f.to_sym]} +0000"
      end
      %w[gross fee net].each do |f|
        row["#{f}_gbp".to_sym] = Money.new(row[f.to_sym].to_f * 100, row[:currency]).exchange_to('GBP').cents.to_f / 100.to_f
      end
      rows << row
    end

    worksheet.instance_variable_get(:@session).sheets_service.append_spreadsheet_value(
      worksheet.spreadsheet.id,
      worksheet_name,
      Google::Apis::SheetsV4::ValueRange.new(values: rows.map(&:values)),
      value_input_option: 'USER_ENTERED'
    )

    # worksheet.insert_rows(worksheet.num_rows + 1, rows.map(&:values))
    # worksheet.save
  end
end
