class Event
  include Mongoid::Document
  include Mongoid::Timestamps
  include Geocoder::Model::Mongoid
  extend Dragonfly::Model

  belongs_to :account, inverse_of: :events, index: true
  belongs_to :organisation, index: true
  belongs_to :activity, optional: true, index: true
  belongs_to :local_group, optional: true, index: true
  belongs_to :coordinator, class_name: 'Account', inverse_of: :events_coordinating, index: true, optional: true
  belongs_to :revenue_sharer, class_name: 'Account', inverse_of: :events_revenue_sharing, index: true, optional: true
  belongs_to :organiser, class_name: 'Account', inverse_of: :events_organising, index: true, optional: true
  belongs_to :last_saved_by, class_name: 'Account', inverse_of: :events_last_saver, index: true, optional: true
  belongs_to :gathering, optional: true, index: true

  field :name, type: String
  index({ name: 1 })
  field :slug, type: String
  index({ slug: 1 })
  field :start_time, type: Time
  field :end_time, type: Time
  field :location, type: String
  field :coordinates, type: Array
  field :image_uid, type: String
  field :video_uid, type: String
  field :description, type: String
  index({ description: 1 })
  field :email, type: String
  field :facebook_event_url, type: String
  field :feedback_questions, type: String
  field :suggested_donation, type: Float
  field :minimum_donation, type: Float
  field :capacity, type: Integer
  field :affiliate_credit_percentage, type: Integer
  field :extra_info_for_ticket_email, type: String
  field :extra_info_for_recording_email, type: String
  field :notes, type: String
  field :redirect_url, type: String
  field :purchase_url, type: String
  field :currency, type: String
  field :facebook_pixel_id, type: String
  field :time_zone, type: String
  field :questions, type: String
  field :add_a_donation_to, type: String
  field :donation_text, type: String
  field :carousel_text, type: String
  field :select_tickets_intro, type: String
  field :select_tickets_outro, type: String
  field :select_tickets_title, type: String
  field :contribution_gbp_custom, type: Float
  field :oc_slug, type: String
  field :ticket_email_greeting, type: String
  field :ticket_email_title, type: String

  field :revenue_share_to_revenue_sharer, type: Integer
  field :profit_share_to_facilitator, type: Integer
  field :profit_share_to_coordinator, type: Integer
  field :profit_share_to_category_steward, type: Integer
  field :profit_share_to_social_media, type: Integer
  field :stripe_revenue_adjustment, type: Float

  def self.admin_fields
    {
      summary: { type: :text, index: false, edit: false },
      name: { type: :text, full: true },
      slug: :slug,
      start_time: :datetime,
      end_time: :datetime,
      location: :text,
      add_a_donation_to: :text,
      donation_text: :text,
      carousel_text: :text,
      select_tickets_intro: :text,
      select_tickets_outro: :text,
      image: :image,
      video: :file,
      description: :wysiwyg,
      email: :email,
      facebook_event_url: :url,
      feedback_questions: :text_area,
      hide_attendees: :check_box,
      hide_discussion: :check_box,
      refund_deleted_orders: :check_box,
      monthly_donors_only: :check_box,
      no_discounts: :check_box,
      trending: :check_box,
      hide_from_trending: :check_box,
      extra_info_for_ticket_email: :wysiwyg,
      extra_info_for_recording_email: :wysiwyg,
      suggested_donation: :number,
      minimum_donation: :number,
      capacity: :number,
      notes: :text_area,
      redirect_url: :url,
      purchase_url: :url,
      draft: :check_box,
      secret: :check_box,
      hide_few_left: :check_box,
      questions: :text_area,
      zoom_party: :check_box,
      show_emails: :check_box,
      opt_in_facilitator: :check_box,
      hide_organisation_footer: :check_box,
      send_order_notifications: :check_box,
      raw_description: :check_box,
      account_id: :lookup,
      organisation_id: :lookup,
      activity_id: :lookup,
      ticket_types: :collection
    }
  end

  def page_views_count
    PageView.or({ path: "/e/#{slug}" }, { path: "/events/#{id}" }).count
  end

  def self.currencies
    CURRENCY_OPTIONS
  end

  def token
    Token.all.find { |token| token.symbol == currency }
  end

  def chain
    if currency == 'USD'
      Chain.object('Gnosis Chain')
    else
      token.try(:chain)
    end
  end

  def questions_a
    q = (questions || '').split("\n").map(&:strip).reject(&:blank?)
    q.empty? ? [] : q
  end

  %w[no_discounts hide_attendees hide_discussion refund_deleted_orders monthly_donors_only draft secret zoom_party show_emails include_in_parent featured opt_in_facilitator hide_few_left hide_organisation_footer ask_hear_about send_order_notifications raw_description prevent_reminders trending hide_from_trending hide_from_carousels no_tickets_pdf].each do |b|
    field b.to_sym, type: Boolean
    index({ b.to_s => 1 })
  end

  def self.marker_color
    '#FF5241'
  end

  def self.marker_icon
    'fa fa-calendar-o'
  end

  has_many :stripe_charges

  has_many :rpayments, dependent: :destroy

  has_many :posts, as: :commentable, dependent: :destroy
  has_many :subscriptions, as: :commentable, dependent: :destroy
  has_many :comments, as: :commentable, dependent: :destroy
  has_many :comment_reactions, as: :commentable, dependent: :destroy

  has_many :event_sessions, dependent: :destroy

  has_many :account_contributions, dependent: :nullify

  has_many :cohostships, dependent: :destroy
  def cohosts
    Organisation.and(:id.in => cohostships.pluck(:organisation_id))
  end

  def organisation_and_cohosts
    Organisation.and(:id.in => ([organisation.try(:id)] + cohostships.pluck(:organisation_id)).compact)
  end

  def organisationship_for_discount(account)
    organisationship = nil
    if account
      organisation_and_cohosts.order('created_at desc').each do |organisation|
        next unless (o = organisation.organisationships.find_by(account: account))

        organisationship = o if o.monthly_donor? && o.monthly_donor_discount > 0 && (!organisationship || o.monthly_donor_discount > organisationship.monthly_donor_discount)
      end
    end
    organisationship
  end

  has_many :pmails_as_mailable, class_name: 'Pmail', as: :mailable, dependent: :destroy
  has_many :pmails_as_exclusion, class_name: 'Pmail', inverse_of: :event, dependent: :nullify

  has_many :discount_codes, class_name: 'DiscountCode', as: :codeable, dependent: :destroy
  def all_discount_codes
    DiscountCode.and(:id.in =>
      discount_codes.pluck(:id) +
      (organisation ? organisation.discount_codes.pluck(:id) : []) +
      (activity ? activity.discount_codes.pluck(:id) : []) +
      (local_group ? local_group.discount_codes.pluck(:id) : []))
  end

  attr_accessor :prevent_notifications, :tag_names, :duplicate

  has_many :notifications, as: :notifiable, dependent: :destroy
  after_create do
    if circle && !prevent_notifications && live? && public?
      notifications.and(:type.in => %w[created_event updated_event]).destroy_all
      notifications.create! circle: circle, type: 'created_event'
    end
  end
  after_update do
    if circle && !prevent_notifications && live? && public?
      notifications.and(:type.in => %w[created_event updated_event]).destroy_all
      notifications.create! circle: circle, type: 'updated_event'
    end
  end

  def circle
    organisation
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
        if coordinates
          self.time_zone = begin
            Timezone.lookup(*coordinates.reverse)
          rescue Timezone::Error::InvalidZone, Timezone::Error::InvalidConfig
            nil
          end
        end
      else
        self.coordinates = nil
      end
    end
  end

  def recording?
    past? && extra_info_for_recording_email
  end

  def revenue_sharer_organisationship
    organisation.organisationships.find_by(:account => revenue_sharer, :stripe_connect_json.ne => nil) if organisation && revenue_sharer
  end

  before_validation do
    self.name = name.strip if name
    self.suggested_donation = suggested_donation.round(2) if suggested_donation
    self.minimum_donation = nil unless suggested_donation
    self.minimum_donation = minimum_donation.round(2) if minimum_donation
    self.organiser = account if account && !revenue_sharer && !organiser && organisation && organisation.stripe_client_id

    unless slug
      loop do
        self.slug = ([*('a'..'z')].sample + [*('0'..'9')].sample + [*('a'..'z'), *('0'..'9')].sample(3).join)
        break if Event.find_by(slug: slug).nil?
      end
    end

    if new_record? && !duplicate
      errors.add(:organisation, '- you are not an admin of this organisation') if !local_group && !activity && !Organisation.admin?(organisation, account)
      errors.add(:activity, '- you are not an admin of this activity') if activity && !Activity.admin?(activity, account)
      errors.add(:local_group, '- you are not an admin of this local group') if local_group && !LocalGroup.admin?(local_group, account)
    end

    if zoom_party?
      self.local_group = nil
      self.capacity = nil
    end
    self.stripe_revenue_adjustment = 0 unless stripe_revenue_adjustment
    self.revenue_share_to_revenue_sharer = 0 unless revenue_share_to_revenue_sharer
    self.revenue_share_to_revenue_sharer = 0 unless revenue_sharer
    self.profit_share_to_facilitator = 0 if revenue_sharer
    errors.add(:revenue_share_to_revenue_sharer, 'must be present if a revenue sharer is set') if revenue_sharer && !revenue_share_to_revenue_sharer
    errors.add(:organiser, 'or revenue sharer must be set') if !revenue_sharer && !organiser && organisation && organisation.stripe_client_id
    errors.add(:revenue_sharer, 'cannot be set if organiser is set') if revenue_sharer && organiser
    errors.add(:revenue_sharer, 'or organiser must be set for this organisation') if organisation && organisation.require_organiser_or_revenue_sharer && !revenue_sharer && !organiser
    errors.add(:revenue_sharer, 'is not connected to this organisation') if revenue_sharer && !revenue_sharer_organisationship
    self.location = 'Online' if location && location.downcase == 'online'
    errors.add(:revenue_share_to_revenue_sharer, 'must be between 1 and 100') if revenue_share_to_revenue_sharer && revenue_share_to_revenue_sharer != 0 && (revenue_share_to_revenue_sharer < 1 || revenue_share_to_revenue_sharer > 100)
    errors.add(:affiliate_credit_percentage, 'must be between 1 and 100') if affiliate_credit_percentage && (affiliate_credit_percentage < 1 || affiliate_credit_percentage > 100)
    errors.add(:capacity, 'must be greater than 0') if capacity && capacity.zero?
    errors.add(:suggested_donation, 'cannot be less than the minimum donation') if suggested_donation && minimum_donation && suggested_donation < minimum_donation
    errors.add(:oc_slug, "cannot be set until the organisation's Open Collective slug is set") if oc_slug && organisation && !organisation.oc_slug

    {
      zoom_party: false,
      monthly_donors_only: false,
      no_discounts: false,
      include_in_parent: false,
      affiliate_credit_percentage: organisation.try(:affiliate_credit_percentage),
      featured: false,
      show_emails: false,
      opt_in_facilitator: false,
      refund_deleted_orders: true
    }.each do |k, v|
      if !duplicate && !Organisation.admin?(organisation, last_saved_by)
        if new_record?
          send("#{k}=", v)
        elsif send("#{k}_changed?")
          errors.add(:"#{k}", '- you cannot change this setting')
        end
      end
    end
  end

  after_create do
    event_facilitations.create account: organisation.admins.first if organisation && organisation.admins.count == 1
    event_facilitations.create account: revenue_sharer if revenue_sharer

    activity.update_attribute(:hidden, false) if activity
    organisation.try(:update_paid_up)
  end

  after_destroy do
    organisation.try(:update_paid_up)
  end

  after_save do
    if changes['name'] && (post = posts.find_by(subject: "Chat for #{changes['name'][0]}"))
      post.update_attribute(:subject, "Chat for #{name}")
    end

    if changes['activity_id']
      if activity && activity.privacy == 'open' && changes['activity_id'][0]
        previous_activity = Activity.find(changes['activity_id'][0])
        attendees.each do |account|
          next unless (previous_activityship = previous_activity.activityships.find_by(account: account))

          activity.activityships.create(
            account: account,
            unsubscribed: previous_activityship.unsubscribed,
            hide_membership: previous_activityship.hide_membership,
            receive_feedback: previous_activityship.receive_feedback
          )
        end
      end
      event_feedbacks.update_all(activity_id: activity_id)
    end

    if changes['local_group_id'] && local_group && changes['local_group_id'][0]
      previous_local_group = LocalGroup.find(changes['local_group_id'][0])
      attendees.each do |account|
        next unless (previous_local_groupship = previous_local_group.local_groupships.find_by(account: account))

        local_group.local_groupships.create(
          account: account,
          unsubscribed: previous_local_groupship.unsubscribed,
          hide_membership: previous_local_groupship.hide_membership,
          receive_feedback: previous_local_groupship.receive_feedback
        )
      end
    end

    if organisation && zoom_party
      organisation.local_groups.each do |local_group|
        zoomships.create local_group: local_group
      end
    end
  end

  after_save :clear_cache
  def clear_cache
    Fragment.and(key: %r{/events/#{id}}).destroy_all
  end

  def carousel_name
    return unless organisation && organisation.carousels

    c = nil
    organisation.carousels.order('o desc').each do |carousel|
      next if carousel.name.downcase.include?('past events')

      intersection = event_tags.pluck(:id) & carousel.event_tags.pluck(:id)
      if intersection.count > 0
        c = carousel.name
        break
      end
    end
    c
  end

  def self.admin?(event, account)
    account &&
      event &&
      (
      account.admin? ||
        event.account_id == account.id ||
        event.revenue_sharer_id == account.id ||
        event.organiser_id == account.id ||
        event.coordinator_id == account.id ||
        event.event_facilitations.find_by(account: account) ||
        (event.activity && Activity.admin?(event.activity, account)) ||
        (event.local_group && LocalGroup.admin?(event.local_group, account)) ||
        (event.organisation && Organisation.admin?(event.organisation, account)) ||
        (event.cohosts.any? { |cohost| Organisation.admin?(cohost, account) })
    )
  end

  def accounts_receiving_feedback
    a = [account, revenue_sharer, coordinator].compact
    a += event_facilitators
    a += organisation.admins_receiving_feedback if organisation
    a += activity.admins_receiving_feedback if activity
    a += local_group.admins_receiving_feedback if local_group
    a.uniq
  end

  def discussers
    Account.and(:id.in =>
        [account.try(:id), revenue_sharer.try(:id), coordinator.try(:id)].compact +
        event_facilitators.pluck(:id) +
        tickets.complete.and(subscribed_discussion: true).pluck(:account_id))
  end

  def subscribed_members
    Account.and(:id.in =>
        [account.try(:id), revenue_sharer.try(:id), coordinator.try(:id)].compact +
        event_facilitators.pluck(:id) +
        attendees.pluck(:id))
  end

  def self.participant?(event, account)
    (account && event.tickets.complete.find_by(account: account)) || Event.admin?(event, account)
  end

  def self.email_viewer?(event, account)
    account && event && ((event.show_emails && Event.admin?(event, account)) || Organisation.admin?(event.organisation, account))
  end

  has_many :ticket_types, dependent: :destroy
  accepts_nested_attributes_for :ticket_types, allow_destroy: true, reject_if: ->(attributes) { %w[name description price quantity].all? { |f| attributes[f].nil? } }

  has_many :ticket_groups, dependent: :destroy
  accepts_nested_attributes_for :ticket_groups, allow_destroy: true, reject_if: ->(attributes) { %w[name capacity].all? { |f| attributes[f].nil? } }

  has_many :tickets, dependent: :destroy
  has_many :donations, dependent: :nullify
  has_many :orders, dependent: :destroy
  has_many :waitships, dependent: :destroy
  def waiters
    Account.and(:id.in => waitships.pluck(:account_id))
  end
  has_many :event_feedbacks, dependent: :destroy
  has_many :event_facilitations, dependent: :destroy
  def event_facilitators
    Account.and(:id.in => event_facilitations.pluck(:account_id))
  end
  has_many :zoomships, dependent: :destroy

  has_many :event_tagships, dependent: :destroy
  has_many :event_stars, dependent: :destroy

  after_save :update_event_tags
  def update_event_tags
    @tag_names ||= ''
    @tag_names_a = @tag_names.split(',').map { |tag_name| tag_name.strip.gsub(' & ', ' and ') }
    current_tag_names = event_tagships.map(&:event_tag_name)
    tags_to_remove = current_tag_names - @tag_names_a
    tags_to_add = @tag_names_a - current_tag_names
    tags_to_remove.each do |name|
      event_tag = EventTag.find_by(name: name)
      event_tagships.find_by(event_tag: event_tag).destroy
    end
    tags_to_add.each do |name|
      if (event_tag = EventTag.find_or_create_by(name: name)).persisted?
        event_tagships.create(event_tag: event_tag)
      end
    end
  end

  def duplicate!(account)
    event = Event.create!(
      duplicate: true,
      name: name,
      start_time: start_time,
      end_time: end_time,
      currency: currency,
      location: location,
      image: image,
      video: video,
      description: description,
      email: email,
      feedback_questions: feedback_questions,
      suggested_donation: suggested_donation,
      minimum_donation: minimum_donation,
      affiliate_credit_percentage: affiliate_credit_percentage,
      capacity: capacity,
      revenue_share_to_revenue_sharer: revenue_share_to_revenue_sharer,
      hide_attendees: hide_attendees,
      hide_discussion: hide_discussion,
      refund_deleted_orders: refund_deleted_orders,
      monthly_donors_only: monthly_donors_only,
      no_discounts: no_discounts,
      extra_info_for_ticket_email: extra_info_for_ticket_email,
      extra_info_for_recording_email: extra_info_for_recording_email,
      zoom_party: zoom_party,
      show_emails: show_emails,
      include_in_parent: include_in_parent,
      opt_in_facilitator: opt_in_facilitator,
      draft: true,
      secret: secret,
      account: account,
      last_saved_by: account,
      organisation: organisation,
      activity: activity,
      local_group: local_group,
      coordinator: coordinator,
      revenue_sharer: revenue_sharer,
      organiser: (organiser || account unless revenue_sharer),
      tag_names: event_tags.pluck(:name).join(','),
      add_a_donation_to: add_a_donation_to,
      donation_text: donation_text,
      carousel_text: carousel_text,
      select_tickets_intro: select_tickets_intro,
      select_tickets_outro: select_tickets_outro,
      select_tickets_title: select_tickets_title,
      ask_hear_about: ask_hear_about,
      time_zone: time_zone,
      questions: questions
    )
    event_tags.each do |event_tag|
      event.event_tagships.create(
        event_tag: event_tag
      )
    end
    event_facilitations.each do |event_facilitation|
      event.event_facilitations.create(
        account: event_facilitation.account
      )
    end
    cohostships.each do |cohostship|
      event.cohostships.create(
        organisation: cohostship.organisation,
        image: cohostship.image,
        video: cohostship.video
      )
    end
    ticket_groups.each do |ticket_group|
      event.ticket_groups.create(
        name: ticket_group.name,
        capacity: ticket_group.capacity
      )
    end
    ticket_types.each do |ticket_type|
      event.ticket_types.create(
        name: ticket_type.name,
        description: ticket_type.description,
        price: ticket_type.price,
        range_min: ticket_type.range_min,
        range_max: ticket_type.range_max,
        quantity: ticket_type.quantity,
        hidden: ticket_type.hidden,
        order: ticket_type.order,
        max_quantity_per_transaction: ticket_type.max_quantity_per_transaction,
        ticket_group: (event.ticket_groups.find_by(name: ticket_type.ticket_group.name) if ticket_type.ticket_group)
      )
    end
    event
  end

  def event_tags
    EventTag.and(:id.in => event_tagships.pluck(:event_tag_id))
  end

  def summary
    start_time ? "#{name} (#{start_time.to_date})" : name
  end

  def self.course
    self.and(:id.in =>
      EventTagship.and(:event_tag_id.in =>
        EventTag.and(:name.in => %w[course courses]).pluck(:id)).pluck(:event_id))
  end

  dragonfly_accessor :video

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

      begin
        self.image = image.encode('jpg') if image && !%w[jpg jpeg].include?(image.format)
      rescue StandardError
        self.image = nil
      end

      errors.add(:image, 'must be at least 992px wide') if image && image.width < 800 # legacy images are 800px
      errors.add(:image, 'must be more wide than high') if image && image.height > image.width

      errors.add(:image, "must be #{organisation.event_image_required_width}px wide") if organisation && organisation.event_image_required_width && !(image && image.width == organisation.event_image_required_width)
      errors.add(:image, "must be #{organisation.event_image_required_height}px high") if organisation && organisation.event_image_required_height && !(image && image.height == organisation.event_image_required_height)

    end
  end

  def cap
    if contribution_gbp_custom
      Money.new(contribution_gbp_custom * 100, 'GBP')
    elsif organisation && organisation.contribution_requested_per_event_gbp
      Money.new(organisation.contribution_requested_per_event_gbp * 100, 'GBP')
    else
      Money.new(Organisation.contribution_requested_per_event_gbp * 100, 'GBP')
    end
  end

  def contribution_gbp
    if organisation && organisation.fixed_fee
      cap
    else
      begin
        if ticket_types.empty?
          cap
        else
          five_percent_of_ticket_sales = Money.new(tickets.complete.sum(:discounted_price) * 0.05 * 100, currency).exchange_to('GBP')
          [cap, five_percent_of_ticket_sales].min
        end
      rescue StandardError
        cap
      end
    end
  end

  def feedback_questions_a
    q = (feedback_questions || '').split("\n").map(&:strip).reject(&:blank?)
    q.empty? ? [] : q
  end

  def send_destroy_notification(destroyed_by)
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    event = self
    content = ERB.new(File.read(Padrino.root('app/views/emails/event_destroyed.erb'))).result(binding)
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "#{destroyed_by.name} deleted the event #{event.name}"
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    accounts_receiving_feedback.each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
  end

  def send_reminders(account_id)
    return unless organisation
    return if prevent_reminders

    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    event = self
    content = ERB.new(File.read(Padrino.root('app/views/emails/reminder.erb'))).result(binding)
    batch_message.from ENV['REMINDERS_EMAIL_FULL']
    batch_message.reply_to(event.email || event.organisation.try(:reply_to))
    batch_message.subject "#{event.name} is tomorrow"
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    (account_id == :all ? attendees.and(:unsubscribed.ne => true).and(:unsubscribed_reminders.ne => true) : attendees.and(:unsubscribed.ne => true).and(:unsubscribed_reminders.ne => true).and(id: account_id)).each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
  end
  handle_asynchronously :send_reminders

  def send_star_reminders(account_id)
    return unless organisation

    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    event = self
    content = ERB.new(File.read(Padrino.root('app/views/emails/reminder_starred.erb'))).result(binding)
    batch_message.from ENV['REMINDERS_EMAIL_FULL']
    batch_message.reply_to(event.email || event.organisation.try(:reply_to))
    batch_message.subject "#{event.name} is next week"
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    (account_id == :all ? starrers.and(:unsubscribed.ne => true).and(:unsubscribed_reminders.ne => true) : starrers.and(:unsubscribed.ne => true).and(:unsubscribed_reminders.ne => true).and(id: account_id)).each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
  end
  handle_asynchronously :send_star_reminders

  def send_feedback_requests(account_id)
    return if feedback_questions.nil?
    return unless organisation

    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    event = self
    content = ERB.new(File.read(Padrino.root('app/views/emails/feedback.erb'))).result(binding)
    batch_message.from ENV['FEEDBACK_EMAIL_FULL']
    batch_message.reply_to(event.email || event.organisation.try(:reply_to))
    batch_message.subject "Feedback on #{event.name}"
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    (account_id == :all ? attendees.and(:unsubscribed.ne => true).and(:unsubscribed_feedback.ne => true) : attendees.and(:unsubscribed.ne => true).and(:unsubscribed_feedback.ne => true).and(id: account_id)).each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
  end
  handle_asynchronously :send_feedback_requests

  before_validation :ensure_end_after_start
  def ensure_end_after_start
    errors.add(:end_time, 'must be after the start time') if end_time && start_time && end_time <= start_time
  end

  validates_presence_of :name, :start_time, :end_time, :location, :currency
  validates_uniqueness_of :slug, allow_nil: true
  validates_format_of :slug, with: /\A[a-z0-9-]+\z/, if: :slug

  def future?(from = Date.today)
    start_time >= from
  end

  def self.future(from = Date.today)
    self.and(:start_time.gte => from).order('start_time asc')
  end

  def self.current(from = Date.today)
    self.and(:end_time.gte => from).order('start_time asc')
  end

  def self.future_and_current_featured(from = Date.today)
    self.and(:id.in => future(from).pluck(:id) + current(from).and(featured: true).pluck(:id)).order('start_time asc')
  end

  def self.future_and_current(from = Date.today)
    self.and(:id.in => future(from).pluck(:id) + current(from).pluck(:id)).order('start_time asc')
  end

  def past?(from = Date.today)
    start_time < from
  end

  def self.past(from = Date.today)
    self.and(:start_time.lt => from).order('start_time desc')
  end

  def finished?(from = Date.today)
    end_time < from
  end

  def self.finished(from = Date.today)
    self.and(:end_time.lt => from).order('start_time desc')
  end

  def self.online
    self.and(location: 'Online')
  end

  def online?
    location == 'Online'
  end

  def self.in_person
    self.and(:location.ne => 'Online')
  end

  def in_person?
    location != 'Online'
  end

  def self.trending
    live.public.legit.future.and(:image_uid.ne => nil, :hide_from_trending.ne => true).and(
      :organisation_id.in => Organisation.and(paid_up: true).pluck(:id)
    ).sort_by do |event|
      [event.trending ? 0 : 1, -event.orders.complete.and(:created_at.gt => 1.week.ago).count]
    end
  end

  def self.legit
    self.and(:organisation_id.in => Organisation.and(:hidden.ne => true).pluck(:id))
  end

  def self.draft
    self.and(draft: true)
  end

  def self.live
    self.and(:draft.ne => true).and(:organisation_id.ne => nil)
  end

  def self.secret
    self.and(secret: true)
  end

  def self.public
    self.and(:secret.ne => true).and(:organisation_id.ne => nil)
  end

  def live?
    !draft?
  end

  def public?
    !secret?
  end

  def time_zone_or_default
    time_zone || ENV['DEFAULT_TIME_ZONE']
  end

  def when_details(zone, with_zone: true)
    return unless start_time && end_time

    zone ||= time_zone_or_default
    zone = time_zone if time_zone && location != 'Online'
    zone = zone.name unless zone.is_a?(String)
    start_time = self.start_time.in_time_zone(zone)
    end_time = self.end_time.in_time_zone(zone)
    z = "#{start_time.strftime('%Z')} (UTC #{start_time.formatted_offset})"
    if start_time.to_date == end_time.to_date
      "#{start_time.to_date}, #{start_time.to_fs(:no_double_zeros)} – #{end_time.to_fs(:no_double_zeros)} #{z if with_zone}"
    else
      "#{start_time.to_date}, #{start_time.to_fs(:no_double_zeros)} – #{end_time.to_date}, #{end_time.to_fs(:no_double_zeros)} #{z if with_zone}"
    end
  end

  def concise_when_details(zone, with_zone: false)
    return unless start_time && end_time

    zone ||= time_zone_or_default
    zone = time_zone if time_zone && location != 'Online'
    zone = zone.name unless zone.is_a?(String)
    start_time = self.start_time.in_time_zone(zone)
    end_time = self.end_time.in_time_zone(zone)
    z = "#{start_time.strftime('%Z')} (UTC #{start_time.formatted_offset})"
    if start_time.to_date == end_time.to_date
      start_time.to_date
    else
      "#{start_time.to_date} – #{end_time.to_date} #{z if with_zone}"
    end
  end

  def self.human_attribute_name(attr, options = {})
    {
      description: 'Public event description',
      name: 'Event title',
      slug: 'Short URL',
      email: 'Contact email',
      questions: 'Further questions to ask on the order form',
      facebook_event_url: 'Facebook event URL',
      facebook_pixel_id: 'Facebook Pixel ID',
      show_emails: 'Allow all event admins to view email addresses of attendees',
      opt_in_facilitator: 'Allow people to opt in to emails from facilitators',
      refund_deleted_orders: 'Refund deleted orders/tickets on Stripe',
      redirect_url: 'Redirect URL after successful payment',
      include_in_parent: 'Include in parent organisation event listings',
      zoom_party: 'Zoom party',
      add_a_donation_to: 'Text above donation field',
      donation_text: 'Text below donation field',
      start_time: 'Start date/time',
      end_time: 'End date/time',
      extra_info_for_ticket_email: 'Extra info for ticket confirmation email',
      extra_info_for_recording_email: 'Extra info for recording confirmation email',
      purchase_url: 'Ticket purchase URL',
      no_discounts: 'No discounts for monthly donors',
      notes: 'Private notes',
      ask_hear_about: 'Ask people how they heard about the event',
      capacity: 'Total capacity',
      gathering_id: 'Add people that buy tickets to this gathering',
      send_order_notifications: 'Send email notifications of orders',
      prevent_reminders: 'Prevent reminder email',
      oc_slug: 'Open Collective event slug',
      no_tickets_pdf: "Don't attach tickets PDF to confirmation email",
      hide_few_left: "Hide 'few tickets left' labels"
    }[attr.to_sym] || super
  end

  def self.new_hints
    {
      slug: 'Lowercase letters, numbers and dashes only (no spaces)',
      image: 'At least 992px wide, and more wide than high',
      start_time: "in &hellip; (your profile's time zone)",
      end_time: "in &hellip; (your profile's time zone)",
      add_a_donation_to: "Text to display above the 'Add a donation' field (leave blank to use organisation default)",
      oc_slug: 'Event slug for taking payments via Open Collective',
      donation_text: "Text to display below the 'Add a donation' field  (leave blank to use organisation default)",
      carousel_text: 'Text to show when hovering over the event in a carousel',
      select_tickets_title: 'Title of the Select Tickets panel',
      select_tickets_intro: 'Text to show at the top of the Select Tickets panel',
      select_tickets_outro: 'Text to show at the bottom of the Select Tickets panel',
      ask_hear_about: 'Ask people how they heard about the event on the order form',
      suggested_donation: 'If this is blank, the donation field will not be shown',
      questions: 'Questions to ask participants upon booking. One question per line. Wrap in [square brackets] to turn into a checkbox, add a [star]* to make a checkbox required. View answers on the Orders page.',
      feedback_questions: 'Questions to ask participants in the post-event feedback form. One question per line. Leave blank to disable feedback.',
      extra_info_for_ticket_email: 'This is the place to enter Zoom links, directions to the venue, etc.',
      extra_info_for_recording_email: 'This is the place to enter the link to the recording.',
      featured: "Feature the event in a carousel on the organisation's events page",
      secret: 'Hide the event from all public listings',
      draft: 'Make the event visible to admins only',
      hide_attendees: 'Hide the public list of attendees (in any case, individuals must opt in)',
      hide_discussion: 'Hide the private discussion for attendees and facilitators',
      hide_from_carousels: 'Hide the event from carousels',
      show_emails: 'Allow all event admins to view attendee emails (by default, only organisation admins see them)',
      opt_in_facilitator: "Allow people to opt in to receive emails from any facilitators' personal lists",
      monthly_donors_only: 'Only allow people making a monthly donation to the organisation to purchase tickets',
      no_discounts: "Don't apply usual discounts for monthly donors to the organisation",
      include_in_parent: 'If the event has a local group, show it in the event listings of the parent organisation',
      refund_deleted_orders: 'Refund deleted orders/tickets via Stripe, and all orders if the event is deleted',
      redirect_url: 'Optional. By default people will be shown a thank you page on Dandelion.',
      facebook_pixel_id: 'Your Facebook Pixel ID for tracking sales',
      purchase_url: "URL where people can buy tickets (if you're not selling tickets on Dandelion)",
      capacity: 'Caps the total number of tickets issued across all ticket types. Optional',
      send_order_notifications: 'Send email notifications of orders to event facilitators',
      prevent_reminders: 'Prevent reminder email from being sent before the event'
    }
  end

  def self.edit_hints
    {}.merge(new_hints)
  end

  def ical(order: nil)
    event = self
    cal = Icalendar::Calendar.new
    cal.append_custom_property('METHOD', 'REQUEST') if order
    cal.event do |e|
      e.summary = (event.start_time.to_date == event.end_time.to_date ? event.name : "#{event.name} starts")
      e.dtstart = (event.start_time.to_date == event.end_time.to_date ? event.start_time.utc.strftime('%Y%m%dT%H%M%SZ') : Icalendar::Values::Date.new(event.start_time.to_date))
      e.dtend = (event.start_time.to_date == event.end_time.to_date ? event.end_time.utc.strftime('%Y%m%dT%H%M%SZ') : nil)
      e.transp = (event.start_time.to_date == event.end_time.to_date ? 'OPAQUE' : 'TRANSPARENT')
      e.location = event.location
      e.description = order ? %(#{ENV['BASE_URI']}/orders/#{order.id}) : %(#{ENV['BASE_URI']}/events/#{event.id})
      e.organizer = event.email
      e.uid = event.id.to_s
      if order
        e.status = 'CONFIRMED'
        e.attendee = Icalendar::Values::CalAddress.new(
          "mailto:#{order.account.email}",
          cn: order.account.email,
          role: 'REQ-PARTICIPANT',
          partstat: 'ACCEPTED',
          cutype: 'INDIVIDUAL'
        )
      end
    end
    cal
  end

  def sold_out?
    ticket_types.count > 0 && ticket_types.and(:hidden.ne => true).all? { |ticket_type| ticket_type.number_of_tickets_available_in_single_purchase <= 0 }
  end

  def tickets_available?
    ticket_types.count > 0 && ticket_types.and(:hidden.ne => true).any? { |ticket_type| ticket_type.number_of_tickets_available_in_single_purchase >= 1 }
  end

  def places_remaining
    capacity - tickets.count if capacity
  end

  def attendees
    Account.and(:id.in => tickets.complete.pluck(:account_id))
  end

  def starrers
    Account.and(:id.in => event_stars.pluck(:account_id))
  end

  def public_attendees
    Account.and(:id.in => tickets.complete.and(show_attendance: true).pluck(:account_id)).and(:hidden.ne => true)
  end

  def private_attendees
    Account.and(:id.in => tickets.complete.and(:show_attendance.ne => true).pluck(:account_id))
  end

  def discounted_ticket_revenue
    r = Money.new(0, currency)
    tickets.complete.each { |ticket| r += Money.new((ticket.discounted_price || 0) * 100, ticket.currency) }
    r
  rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
    Money.new(0, ENV['DEFAULT_CURRENCY'])
  end

  def donation_revenue(skip_transferred: false)
    r = Money.new(0, currency)
    donations = skip_transferred ? self.donations.and(:transferred.ne => true) : self.donations
    donations.each { |donation| r += Money.new((donation.amount || 0) * 100, donation.currency) }
    r
  rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
    Money.new(0, ENV['DEFAULT_CURRENCY'])
  end

  def organisation_discounted_ticket_revenue(skip_transferred: false)
    r = Money.new(0, currency)
    tickets = skip_transferred ? self.tickets.and(:transferred.ne => true) : self.tickets
    tickets.complete.each { |ticket| r += Money.new((ticket.discounted_price || 0) * 100 * (ticket.organisation_revenue_share || 1), ticket.currency) }
    r
  rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
    Money.new(0, ENV['DEFAULT_CURRENCY'])
  end

  def revenue_sharer_discounted_ticket_revenue(skip_transferred: false)
    r = Money.new(0, currency)
    tickets = skip_transferred ? self.tickets.and(:transferred.ne => true) : self.tickets
    tickets.complete.each { |ticket| r += Money.new((ticket.discounted_price || 0) * 100 * (1 - (ticket.organisation_revenue_share || 1)), ticket.currency) }
    r
  rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
    Money.new(0, ENV['DEFAULT_CURRENCY'])
  end

  def revenue_share_to_organisation
    100 - revenue_share_to_revenue_sharer
  end

  def organisation_revenue_share
    revenue_share_to_organisation / 100.0
  end

  def revenue
    organisation_discounted_ticket_revenue(skip_transferred: true) + donation_revenue(skip_transferred: true) - (credit_applied - credit_payable_to_revenue_sharer)
  end

  def ticket_revenue_to_revenue_sharer
    revenue_sharer_discounted_ticket_revenue(skip_transferred: true)
  end

  def stripe_revenue
    s = stripe_charges.sum(&:balance)
    s == 0 ? Money.new(0, currency) : s
  end

  def stripe_fees
    s = stripe_charges.sum(&:fees)
    s == 0 ? Money.new(0, currency) : s
  end

  def stripe_donations
    s = stripe_charges.sum(&:donations)
    s == 0 ? Money.new(0, currency) : s
  end

  def stripe_ticket_revenue
    s = stripe_charges.sum(&:ticket_revenue)
    s == 0 ? Money.new(0, currency) : s
  end

  def stripe_ticket_revenue_to_organisation
    s = stripe_charges.sum(&:ticket_revenue_to_organisation)
    s == 0 ? Money.new(0, currency) : s
  end

  def stripe_ticket_revenue_to_revenue_sharer
    s = stripe_charges.sum(&:ticket_revenue_to_revenue_sharer)
    s == 0 ? Money.new(0, currency) : s
  end

  def stripe_profit
    stripe_revenue - stripe_fees + Money.new(stripe_revenue_adjustment * 100, currency)
  end

  def profit
    stripe_profit
  end

  def profit_less_donations
    stripe_profit - stripe_donations
  end

  def self.profit_share_roles
    %w[facilitator coordinator category_steward social_media]
  end

  def allocations_to_roles
    allocations = Money.new(0, currency)
    Event.profit_share_roles.each do |role|
      allocations += send("profit_to_#{role}")
    end
    allocations
  end

  def profit_less_donations_less_allocations
    profit_less_donations - allocations_to_roles
  end

  def profit_less_allocations
    profit_less_donations_less_allocations + stripe_donations
  end

  before_validation do
    Event.profit_share_roles.each do |role|
      send("profit_share_to_#{role}=", 0) if send("profit_share_to_#{role}").nil?
    end
    Event.profit_share_roles.each do |role|
      errors.add(:"profit_share_to_#{role}", 'must be between 0% and 100%') if send("profit_share_to_#{role}") < 0 || send("profit_share_to_#{role}") > 100
      errors.add(:"profit_share_to_#{role}", "along with other profit shares must not be greater than #{revenue_share_to_organisation}%") if Event.profit_share_roles.inject(0) { |sum, r| sum + send("profit_share_to_#{r}") } > revenue_share_to_organisation
    end
  end

  Event.profit_share_roles.each do |role|
    define_method "paid_to_#{role}" do
      s = rpayments.and(role: role).sum(&:amount_money)
      s == 0 ? Money.new(0, currency) : s
    end
    define_method "remaining_to_#{role}" do
      send("profit_to_#{role}") - send("paid_to_#{role}")
    end
  end

  (Event.profit_share_roles + ['organisation']).each do |role|
    define_method "profit_to_#{role}" do
      revenue_share_to_organisation > 0 ? profit_less_donations * send("profit_share_to_#{role}") / revenue_share_to_organisation : Money.new(0, currency)
    end
  end

  def profit_share_to_organisation
    revenue_share_to_organisation - Event.profit_share_roles.inject(0) { |sum, r| sum + send("profit_share_to_#{r}") }
  end

  def credit_applied
    r = Money.new(0, currency)
    orders.each { |order| r += Money.new((order.credit_applied || 0) * 100, order.currency) }
    r
  rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
    Money.new(0, ENV['DEFAULT_CURRENCY'])
  end

  def credit_payable_to_revenue_sharer
    r = Money.new(0, currency)
    orders.each { |order| r += Money.new((order.credit_payable_to_revenue_sharer || 0) * 100, order.currency) }
    r
  rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
    Money.new(0, ENV['DEFAULT_CURRENCY'])
  end

  def self.oc_transactions(oc_slug)
    transactions = []

    query = %{
      query (
        $account: AccountReferenceInput
      ) {
        orders(account: $account) {
          nodes {
            legacyId
            createdAt
            tags
            amount {
              value
              currency
              valueInCents
            }
          }
        }
      }
    }

    variables = { account: { slug: oc_slug } }

    conn = Faraday.new(url: 'https://api.opencollective.com/graphql/v2/') do |faraday|
      faraday.request  :url_encoded
      faraday.adapter  Faraday.default_adapter
      faraday.headers['Content-Type'] = 'application/json'
      faraday.headers['Api-Key'] = ENV['OC_API_KEY']
    end

    response = conn.post do |req|
      req.body = {
        query: query,
        variables: variables
      }.to_json
    end

    j = JSON.parse(response.body)
    j['data']['orders']['nodes'].each do |item|
      currency = item['amount']['currency']
      amount = item['amount']['value']
      secret = item['tags'].select { |tag| tag.starts_with?('dandelion:') }.first
      tx_created_at = Time.parse(item['createdAt'])

      puts [currency, amount, secret, tx_created_at]
      transactions << [currency, amount, secret, tx_created_at]
    end

    transactions
  end

  def oc_transactions
    Event.oc_transactions(oc_slug)
  end

  def check_oc_event
    oc_transactions.each do |currency, amount, secret, tx_created_at|
      if (@order = Order.find_by(:payment_completed.ne => true, :currency => currency, :value => amount, :oc_secret => secret, :created_at.lt => tx_created_at))
        @order.payment_completed!
        @order.send_tickets
        @order.create_order_notification
      elsif (@order = Order.deleted.find_by(:payment_completed.ne => true, :currency => currency, :value => amount, :oc_secret => secret, :created_at.lt => tx_created_at))
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
