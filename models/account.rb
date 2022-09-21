class Account
  include Mongoid::Document
  include Mongoid::Timestamps
  include Geocoder::Model::Mongoid
  extend Dragonfly::Model

  field :name, type: String
  field :name_transliterated, type: String
  field :ps_account_id, type: String
  index({ ps_account_id: 1 })
  field :email, type: String
  index({ email: 1 }, { unique: true })
  field :phone, type: String
  field :telegram_username, type: String
  field :username, type: String
  index({ username: 1 }, { unique: true })
  field :website, type: String
  field :gender, type: String
  field :sexuality, type: String
  field :date_of_birth, type: Date
  field :dietary_requirements, type: String
  field :time_zone, type: String
  field :crypted_password, type: String
  field :picture_uid, type: String
  field :sign_ins_count, type: Integer
  field :sign_in_token, type: String
  index({ sign_in_token: 1 })
  field :api_key, type: String
  field :facebook_name, type: String
  field :facebook_profile_url, type: String
  field :last_active, type: Time
  field :last_checked_notifications, type: Time
  field :last_checked_messages, type: Time
  field :location, type: String
  field :number_at_this_location, type: Integer
  index({ number_at_this_location: 1 })
  field :coordinates, type: Array
  field :default_currency, type: String
  field :stripe_connect_json, type: String
  field :organisation_ids_cache, type: Array
  index({ organisation_ids_cache: 1 })
  field :organisation_ids_public_cache, type: Array
  index({ organisation_ids_public_cache: 1 })
  field :bio, type: String
  field :can_message, type: Boolean
  field :failed_sign_in_attempts, type: Integer
  field :minimal_head, type: String
  field :recommended_people_cache, type: Array
  field :recommended_events_cache, type: Array

  field :tokens, type: Float
  index({ tokens: 1 })
  def calculate_tokens
    orders.and(:value.ne => nil, :currency.in => MAJOR_CURRENCIES).sum { |o| Math.sqrt(Money.new(o.value * 100, o.currency).exchange_to('GBP').cents) } +
      Order.and(:event_id.in => events_revenue_sharing.pluck(:id), :value.ne => nil, :currency.in => MAJOR_CURRENCIES).sum { |o| 0.25 * Math.sqrt(Money.new(o.value * 100, o.currency).exchange_to('GBP').cents) } +
      payments.and(:amount.ne => nil, :currency.in => MAJOR_CURRENCIES).sum { |p| 2 * Math.sqrt(Money.new(p.amount * 100, p.currency).exchange_to('GBP').cents) } +
      account_contributions.and(:amount.ne => nil, :currency.in => MAJOR_CURRENCIES).sum { |p| Math.sqrt(Money.new(p.amount * 100, p.currency).exchange_to('GBP').cents) }
  end

  %w[email_confirmed
     updated_profile
     admin
     unsubscribed
     unsubscribed_habit_completion_likes
     unsubscribed_messages
     unsubscribed_feedback
     unsubscribed_reminders
     not_on_facebook
     open_to_hookups
     open_to_new_friends
     open_to_short_term_dating
     open_to_long_term_dating
     open_to_open_relating
     hide_location
     block_reply_by_email
     hidden
     seen_intro_tour].each do |b|
    field b.to_sym, type: Boolean
    index({ b.to_s => 1 })
  end

  def self.privacyables
    %w[email location phone telegram_username website facebook_profile_url date_of_birth gender sexuality bio open_to last_active organisations local_groups activities gatherings places following followers]
  end

  def self.privacy_levels
    ['Only me', 'People I follow', 'Public']
  end
  privacyables.each do |p|
    field :"#{p}_privacy", type: String
    index({ "#{p}_privacy" => 1 })
  end

  def self.admin_fields
    {
      email: :email,
      name: :text,
      name_transliterated: { type: :text, disabled: true },
      ps_account_id: :text,
      updated_profile: :check_box,
      facebook_name: :text,
      default_currency: :select,
      phone: :text,
      location: :text,
      number_at_this_location: :number,
      username: :text,
      website: :url,
      gender: :select,
      sexuality: :select,
      date_of_birth: :date,
      facebook_profile_url: :text,
      dietary_requirements: :text,
      picture: :image,
      can_message: :check_box,
      admin: :check_box,
      unsubscribed: :check_box,
      unsubscribed_habit_completion_likes: :check_box,
      unsubscribed_messages: :check_box,
      unsubscribed_feedback: :check_box,
      unsubscribed_reminders: :check_box,
      not_on_facebook: :check_box,
      hide_location: :check_box,
      hidden: :check_box,
      block_reply_by_email: :check_box,
      time_zone: :select,
      password: :password,
      sign_ins_count: :number,
      provider_links: :collection,
      memberships: :collection,
      mapplications: :collection,
      organisationships: :collection,
      tickets: :collection,
      orders: :collection,
      last_active: :datetime,
      stripe_connect_json: :text_area,
      minimal_head: :text_area
    }
  end

  def public?
    sign_ins_count > 0 && !hidden?
  end

  def private?
    !public?
  end

  def able_to_message
    email_confirmed && (can_message || tickets.count > 0 || memberships.count > 0 || account_contributions.count > 0)
  end

  def self.public
    self.and(:sign_ins_count.gt => 0, :hidden.ne => true)
  end

  def self.mappable
    public.and(:updated_profile => true, :hide_location.ne => true)
  end

  def mappable?
    public? && updated_profile? && !hide_location?
  end

  def self.open_to
    %w[new_friends hookups short_term_dating long_term_dating open_relating]
  end

  def open_to
    o = Account.open_to.select { |x| send("open_to_#{x}") }
    o.empty? ? nil : o
  end

  def self.protected_attributes
    %w[admin]
  end

  def self.countries
    [''] + ISO3166::Country.all.sort
  end

  before_validation do
    unless username
      u = Bazaar.super_object.parameterize.underscore
      if Account.find_by(username: u)
        n = 1
        n += 1 while Account.find_by(username: "#{u}_#{n}")
        self.username = "#{u}_#{n}"
      else
        self.username = u
      end
    end

    self.name = username unless name
    self.name = name.split('@').first if name && name.include?('@')

    self.location = "#{postcode}, #{country}" if postcode && country
    self.sign_in_token = SecureRandom.uuid unless sign_in_token
    self.name = name.strip if name
    self.name_transliterated = I18n.transliterate(name) if name
    self.username = username.downcase if username
    self.email = email.downcase.strip if email
    self.sign_ins_count = 0 unless sign_ins_count
    self.number_at_this_location = 0 unless number_at_this_location

    if email_changed?
      e = EmailAddress.error(email)
      errors.add(:email, "- #{e}") if e
      self.email_confirmed = nil
    end

    %w[email phone telegram_username].each do |p|
      send("#{p}_privacy=", 'People I follow') unless send("#{p}_privacy")
    end

    errors.add(:name, 'must not contain $') if name && name.include?('$')
    errors.add(:name, 'must not contain @') if name && name.include?('@')
    errors.add(:name, 'must not contain www.') if name && name.include?('www.')
    errors.add(:name, 'must not contain http://') if name && name.include?('http://')
    errors.add(:name, 'must not contain https://') if name && name.include?('https://')
    # errors.add(:name, 'must not contain digits') if self.name and self.name =~ /\d/

    if !password && !crypted_password
      self.password = Account.generate_password # if there's no password, just set one
    end

    errors.add(:facebook_profile_url, 'must contain facebook.com') if facebook_profile_url && !facebook_profile_url.include?('facebook.com')
    self.facebook_profile_url = "https://#{facebook_profile_url}" if facebook_profile_url && facebook_profile_url !~ %r{\Ahttps?://}
    self.facebook_profile_url = facebook_profile_url.gsub('m.facebook.com', 'facebook.com') if facebook_profile_url

    errors.add(:date_of_birth, 'is invalid') if age && age <= 0
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
    notifications_as_notifiable.create! circle: self, type: 'created_profile'
  end

  after_create :send_confirmation_email
  def send_confirmation_email
    unless skip_confirmation_email
      mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], 'api.eu.mailgun.net'
      batch_message = Mailgun::BatchMessage.new(mg_client, 'notifications.dandelion.earth')

      account = self
      content = ERB.new(File.read(Padrino.root('app/views/emails/confirm_email.erb'))).result(binding)
      batch_message.from 'Dandelion <notifications@dandelion.earth>'
      batch_message.subject 'Confirm your email address'
      batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

      [account].each do |account|
        batch_message.add_recipient(:to, account.email, {
                                      'firstname' => (account.firstname || 'there'),
                                      'token' => account.sign_in_token,
                                      'id' => account.id.to_s,
                                      'confirm_or_activate' => (account.sign_ins_count.zero? ? "If you'd like to activate your account, click the link below:" : 'Click here to confirm your email address:')
                                    })
      end

      batch_message.finalize if ENV['MAILGUN_API_KEY']
    end
  end

  def send_activation_notification
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], 'api.eu.mailgun.net'
    batch_message = Mailgun::BatchMessage.new(mg_client, 'notifications.dandelion.earth')

    account = self
    content = ERB.new(File.read(Padrino.root('app/views/emails/activation_notification.erb'))).result(binding)
    batch_message.from 'Dandelion <notifications@dandelion.earth>'
    batch_message.subject "You've activated your Dandelion account"
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    [account].each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => (account.firstname || 'there'), 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
  end

  def self.marker_color
    '#00B963'
  end

  def self.marker_icon
    'fa fa-user'
  end

  def network
    Account.and(:id.in => follows_as_follower.pluck(:followee_id))
  end

  def discussers
    Account.and(:id.in => [id] + follows_as_followee.and(:unsubscribed.ne => true).pluck(:follower_id))
  end

  def network_notifications
    Notification.all.or(
      { :circle_type => 'Gathering', :circle_id.in => memberships.pluck(:gathering_id) },
      { :circle_type => 'Account', :circle_id.in => [id] + network.pluck(:id) },
      { :circle_type => 'Place', :circle_id.in => places_following.pluck(:id) },
      { :circle_type => 'Activity', :circle_id.in => activities_following.pluck(:id) },
      { :circle_type => 'LocalGroup', :circle_id.in => local_groups_following.pluck(:id) },
      {
        :circle_type => 'Organisation',
        :circle_id.in => organisations_following.pluck(:id),
        :type.ne => 'commented'
      },
      {
        :circle_type => 'Organisation',
        :circle_id.in => organisations_monthly_donor.pluck(:id),
        :type => 'commented'
      }
    )
  end

  has_many :predictions, dependent: :nullify
  has_many :prediction_favs, dependent: :destroy

  has_many :account_contributions, dependent: :destroy

  has_many :sign_ins, dependent: :destroy

  has_many :calendars, dependent: :destroy
  def calendar_events
    calendars.sum { |calendar| calendar.events } if calendars.count > 0
  end

  has_many :pmails, dependent: :nullify
  has_many :pmail_tests, dependent: :nullify

  has_many :uploads, dependent: :destroy

  has_many :organisations, dependent: :nullify
  has_many :organisationships, class_name: 'Organisationship', inverse_of: :account, dependent: :destroy
  has_many :organisationships_as_referrer, class_name: 'Organisationship', inverse_of: :referrer, dependent: :nullify

  def organisations_following
    Organisation.and(:id.in => organisationships.pluck(:organisation_id))
  end

  def organisations_monthly_donor
    Organisation.and(:id.in => organisationships.and(:monthly_donation_method.ne => nil).pluck(:organisation_id))
  end
  has_many :creditings, dependent: :nullify

  has_many :activity_applications, class_name: 'ActivityApplication', inverse_of: :account, dependent: :destroy
  has_many :statused_activity_applications, class_name: 'ActivityApplication', inverse_of: :statused_by, dependent: :nullify

  has_many :services, dependent: :nullify
  has_many :bookings, dependent: :destroy, inverse_of: :account
  has_many :bookings_as_service_provider, class_name: 'Booking', dependent: :destroy, inverse_of: :service_provider

  has_many :events, class_name: 'Event', inverse_of: :account, dependent: :nullify
  has_many :events_coordinating, class_name: 'Event', inverse_of: :coordinator, dependent: :nullify
  has_many :events_revenue_sharing, class_name: 'Event', inverse_of: :revenue_sharer, dependent: :nullify
  has_many :events_last_saver, class_name: 'Event', inverse_of: :last_saved_by, dependent: :nullify
  has_many :event_stars, dependent: :destroy
  has_many :zoomships, dependent: :destroy
  has_many :event_facilitations, dependent: :destroy
  has_many :waitships, dependent: :destroy
  has_many :event_feedbacks, dependent: :destroy
  def event_feedbacks_as_facilitator
    EventFeedback.and(:event_id.in => event_facilitations.pluck(:event_id))
  end
  has_many :activities, dependent: :nullify
  has_many :activityships, dependent: :destroy
  def activities_following
    Activity.and(:id.in => activityships.pluck(:activity_id))
  end
  has_many :local_groups, dependent: :nullify
  has_many :local_groupships, dependent: :destroy
  def local_groups_following
    LocalGroup.and(:id.in => local_groupships.pluck(:local_group_id))
  end

  has_many :places, dependent: :nullify

  has_many :gatherings, dependent: :nullify

  has_many :mapplications, class_name: 'Mapplication', inverse_of: :account, dependent: :destroy
  has_many :mapplications_processed, class_name: 'Mapplication', inverse_of: :processed_by, dependent: :nullify

  has_many :verdicts, dependent: :destroy

  has_many :memberships, class_name: 'Membership', inverse_of: :account, dependent: :destroy
  has_many :memberships_added, class_name: 'Membership', inverse_of: :added_by, dependent: :nullify
  has_many :memberships_admin_status_changed, class_name: 'Membership', inverse_of: :admin_status_changed_by, dependent: :nullify

  has_many :payments, dependent: :destroy
  has_many :payment_attempts, dependent: :destroy

  # Timetable
  has_many :timetables, dependent: :nullify
  has_many :tactivities, class_name: 'Tactivity', inverse_of: :account, dependent: :destroy
  has_many :tactivities_scheduled, class_name: 'Tactivity', inverse_of: :scheduled_by, dependent: :nullify
  has_many :attendances, dependent: :destroy
  # Teams
  has_many :teams, dependent: :nullify
  has_many :teamships, dependent: :destroy
  has_many :read_receipts, dependent: :destroy
  has_many :options, dependent: :destroy
  has_many :votes, dependent: :destroy
  # Rotas
  has_many :rotas, dependent: :nullify
  has_many :shifts, dependent: :destroy
  # Options
  has_many :options, dependent: :nullify
  has_many :optionships, dependent: :destroy
  # Budget
  has_many :spends, dependent: :destroy
  # Inventory
  has_many :inventory_items_listed, class_name: 'InventoryItem', inverse_of: :account, dependent: :nullify
  has_many :inventory_items_provided, class_name: 'InventoryItem', inverse_of: :responsible, dependent: :nullify
  # Habits
  has_many :habits, dependent: :destroy
  has_many :habit_completions, dependent: :destroy
  has_many :habit_completion_likes, dependent: :destroy
  # Follows
  has_many :follows_as_follower, class_name: 'Follow', inverse_of: :follower, dependent: :destroy
  has_many :follows_as_followee, class_name: 'Follow', inverse_of: :followee, dependent: :destroy
  def following
    Account.and(:id.in => follows_as_follower.pluck(:followee_id))
  end

  def following_starred
    Account.and(:id.in => follows_as_follower.and(starred: true).pluck(:followee_id))
  end

  def followers
    Account.and(:id.in => follows_as_followee.pluck(:follower_id))
  end
  # Messages
  has_many :messages_as_messenger, class_name: 'Message', inverse_of: :messenger, dependent: :destroy
  has_many :messages_as_messengee, class_name: 'Message', inverse_of: :messengee, dependent: :destroy
  def messages
    Message.all.or({ messenger: self }, { messengee: self })
  end
  # MessageReceipts
  has_many :message_receipts_as_messenger, class_name: 'MessageReceipt', inverse_of: :messenger, dependent: :destroy
  has_many :message_receipts_as_messengee, class_name: 'MessageReceipt', inverse_of: :messengee, dependent: :destroy
  # Placeships
  has_many :placeships, dependent: :destroy
  def places_following
    Place.and(:id.in => placeships.pluck(:place_id))
  end
  has_many :placeship_categories, dependent: :destroy

  has_many :photos, dependent: :destroy

  has_many :notifications_as_notifiable, as: :notifiable, dependent: :destroy, class_name: 'Notification', inverse_of: :notifiable
  has_many :notifications_as_circle, as: :circle, dependent: :destroy, class_name: 'Notification', inverse_of: :circle

  has_many :posts_as_creator, class_name: 'Post', inverse_of: :account, dependent: :destroy
  has_many :subscriptions_as_creator, class_name: 'Subscription', inverse_of: :account, dependent: :destroy
  has_many :comments_as_creator, class_name: 'Comment', inverse_of: :account, dependent: :destroy
  has_many :comment_reactions_as_creator, class_name: 'CommentReaction', inverse_of: :account, dependent: :destroy

  has_many :posts, as: :commentable, dependent: :destroy
  has_many :subscriptions, as: :commentable, dependent: :destroy
  has_many :comments, as: :commentable, dependent: :destroy
  has_many :comment_reactions, as: :commentable, dependent: :destroy

  has_many :orders, class_name: 'Order', inverse_of: :account, dependent: :nullify
  has_many :orders_as_revenue_sharer, class_name: 'Order', inverse_of: :revenue_sharer, dependent: :nullify
  has_many :orders_as_affiliate, class_name: 'Order', as: :affiliate, dependent: :nullify

  has_many :tickets, dependent: :destroy
  has_many :donations, dependent: :destroy
  def upcoming_events
    Event.future_and_current_featured.and(:id.in =>
        tickets.pluck(:event_id) +
        event_facilitations.pluck(:event_id) +
        events_coordinating.pluck(:id) +
        events_revenue_sharing.pluck(:id) +
        event_stars.pluck(:event_id))
  end

  def previous_events
    Event.past.and(:id.in =>
        tickets.pluck(:event_id) +
        event_facilitations.pluck(:event_id) +
        events_coordinating.pluck(:id) +
        events_revenue_sharing.pluck(:id) +
        event_stars.pluck(:event_id))
  end

  has_many :discount_codes, dependent: :nullify

  dragonfly_accessor :picture
  before_validation do
    if picture
      begin
        errors.add(:picture, 'must be an image') unless %w[jpeg png gif pam].include?(picture.format)
      rescue StandardError
        self.picture = nil
        errors.add(:picture, 'must be an image')
      end
    end
  end

  after_save do
    if location_change
      location_change.each do |l|
        if l
          accounts = Account.and(location: location)
          accounts.set(number_at_this_location: accounts.count)
        end
      end
    end
  end

  def picture_thumb_or_gravatar_url
    if picture
      picture.thumb('400x400#').url
    else
      (Padrino.env == :development ? '/images/silhouette.png' : "https://www.gravatar.com/avatar/#{Digest::MD5.hexdigest(email.downcase)}?s=400&d=#{Addressable::URI.escape("#{ENV['BASE_URI']}/images/silhouette.png")}")
    end
  end

  def unread_notifications?
    (n = network_notifications.order('created_at desc').first) && (!last_checked_notifications || (n.created_at > last_checked_notifications))
  end

  def unread_messages?
    (m = messages_as_messengee.order('created_at desc').first) && (!last_checked_messages || m.created_at > last_checked_messages)
  end

  has_many :provider_links, dependent: :destroy
  accepts_nested_attributes_for :provider_links

  attr_accessor :password, :postcode, :country, :skip_confirmation_email

  validates_presence_of :name, :username, :email
  validates_uniqueness_of   :email,    case_sensitive: false
  validates_presence_of     :password, if: :password_required
  validates_password_strength :password, if: :password_required

  validates_format_of :username, with: /\A[a-z0-9_.]+\z/
  validates_uniqueness_of :username

  validates_uniqueness_of :ps_account_id, allow_nil: true

  def self.default_currencies
    [''] + CURRENCIES_HASH
  end

  def self.new_hints
    {
      location: 'Locations are offset for privacy, and locations with numbers in (e.g. postcodes) are never displayed publicly.',
      date_of_birth: 'We use this to calculate your age. Your full date of birth is never displayed.',
      not_on_facebook: 'Hides some Facebook-related features',
      time_zone: 'Dates/times will be displayed in this time zone'
    }
  end

  def self.edit_hints
    {
      password: 'Leave blank to keep existing password'
    }.merge(new_hints)
  end

  def self.new_tips
    {
      username: 'Letters, numbers, underscores and periods'
    }
  end

  def self.edit_tips
    {}.merge(new_tips)
  end

  def self.sexualities
    [''] + %(Straight
Gay
Bisexual
Asexual
Demisexual
Heteroflexible
Homoflexible
Lesbian
Pansexual
Queer
Questioning
Sapiosexual).split("\n")
  end

  def self.genders
    [''] + %(Woman
Man
Agender
Androgynous
Bigender
Cis Man
Cis Woman
Genderfluid
Genderqueer
Gender Nonconforming
Hijra
Intersex
Non-binary
Other
Pangender
Transfeminine
Transgender
Transmasculine
Transsexual
Trans Man
Trans Woman
Two Spirit).split("\n")
  end

  def pronoun
    case gender
    when 'Man'
      'his'
    when 'Woman'
      'her'
    else
      'their'
    end
  end

  def age
    if (dob = date_of_birth)
      now = Time.now.utc.to_date
      now.year - dob.year - (now.month > dob.month || (now.month == dob.month && now.day >= dob.day) ? 0 : 1)
    end
  end

  def self.radio_scopes
    []
  end

  def self.check_box_scopes
    y = []

    y << [:open_to_new_friends, 'Open to new friends', self.and(open_to_new_friends: true)]
    y << [:open_to_hookups, 'Open to hookups', self.and(open_to_hookups: true)]
    y << [:open_to_short_term_dating, 'Open to short-term dating', self.and(open_to_short_term_dating: true)]
    y << [:open_to_long_term_dating, 'Open to long-term dating', self.and(open_to_long_term_dating: true)]
    y << [:open_to_open_relating, 'Open to open relating', self.and(open_to_open_relating: true)]

    y
  end

  def self.human_attribute_name(attr, options = {})
    {
      picture: 'Photo',
      facebook_profile_url: 'Facebook profile URL',
      not_on_facebook: "I don't use Facebook",
      unsubscribed: 'Opt out of all emails from Dandelion',
      unsubscribed_habit_completion_likes: 'Opt out of email notifications when people like my habit completions',
      unsubscribed_messages: 'Opt out of email notifications of direct messages',
      unsubscribed_feedback: 'Opt out of requests for feedback',
      unsubscribed_reminders: 'Opt out of event reminders',
      hide_location: "Don't show me on maps",
      hidden: 'Make my profile private and visible only to me',
      hear_about: 'How did you hear about this event?',
      client_note: 'Add a note'
    }[attr.to_sym] || super
  end

  def firstname
    unless name.blank?
      parts = name.split(' ')
      n = if parts.count > 1 && %w[mr mrs ms dr].include?(parts[0].downcase.gsub('.', ''))
            parts[1]
          else
            parts[0]
          end
      n.capitalize
    end
  end

  def lastname
    if name
      nameparts = name.split(' ')
      nameparts[1..-1].join(' ') if nameparts.length > 1
    end
  end

  def abbrname
    if firstname
      firstname.capitalize + (lastname ? (' ' + lastname[0].upcase + '.') : '')
    end
  end

  def self.time_zones
    [''] + ActiveSupport::TimeZone::MAPPING.keys.sort
  end

  def uid
    id
  end

  def info
    { email: email, name: name }
  end

  def self.authenticate(email, password)
    if email.present? && (account = find_by(email: email.downcase))
      if account.failed_sign_in_attempts && account.failed_sign_in_attempts >= 5
        nil
      elsif account.has_password?(password)
        account.update_attribute(:failed_sign_in_attempts, 0)
        account
      else
        account.update_attribute(:failed_sign_in_attempts, (account.failed_sign_in_attempts || 0) + 1)
        nil
      end
    end
  end

  before_save :encrypt_password, if: :password_required

  def has_password?(password)
    ::BCrypt::Password.new(crypted_password) == password
  end

  def self.generate_password
    chars = ('a'..'z').to_a + ('0'..'9').to_a
    Array.new(16) { chars[rand(chars.size)] }.join
  end

  def sign_in_link!
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], 'api.eu.mailgun.net'
    batch_message = Mailgun::BatchMessage.new(mg_client, 'notifications.dandelion.earth')

    account = self
    content = ERB.new(File.read(Padrino.root('app/views/emails/sign_in_link.erb'))).result(binding)
    batch_message.from 'Dandelion <notifications@dandelion.earth>'
    batch_message.subject 'Sign in link for Dandelion'
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    [account].each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => (account.firstname || 'there'), 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
  end

  def self.recommendable
    Account.and(:id.in => Ticket.pluck(:account_id) + EventFacilitation.pluck(:account_id))
  end

  def recommended_people
    events = Event.and(:id.in => tickets.pluck(:event_id))
    people = {}
    events.each do |event|
      event.attendees.pluck(:id).each do |attendee_id|
        next if attendee_id == id

        if people[attendee_id.to_s]
          people[attendee_id.to_s] << event.id.to_s
        else
          people[attendee_id.to_s] = [event.id.to_s]
        end
      end
    end
    people = people.sort_by { |_k, v| -v.count }
    update_attribute(:recommended_people_cache, people)
  end

  def recommended_events(events_with_participant_ids = Event.live.public.future.map do |event|
    [event.id.to_s, event.attendees.pluck(:id).map(&:to_s)]
  end, people = recommended_people_cache)
    events = events_with_participant_ids.map do |event_id, participant_ids|
      if participant_ids.include?(id.to_s)
        nil
      else
        [event_id, people.select { |k, _v| participant_ids.include?(k) }]
      end
    end.compact
    events = events.select { |_event_id, people| people.map { |_k, v| v }.flatten.count > 0 }
    events = events.sort_by { |_event_id, people| -people.map { |_k, v| v }.flatten.count }
    update_attribute(:recommended_events_cache, events)
  end

  private

  def encrypt_password
    self.crypted_password = ::BCrypt::Password.create(password)
  end

  def password_required
    crypted_password.blank? || password.present?
  end
end
