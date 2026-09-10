class Organisationship
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  include Geocoder::Model::Mongoid

  belongs_to_without_parent_validation :organisation
  belongs_to_without_parent_validation :account, inverse_of: :organisationships

  field :stripe_connect_json, type: String
  field :stripe_account_json, type: String
  field :monthly_donation_method, type: String
  field :monthly_donation_amount, type: Float
  field :monthly_donation_currency, type: String
  field :monthly_donation_start_date, type: Date
  field :monthly_donation_postcode, type: String
  field :monthly_donation_annual, type: Boolean
  field :coordinates, type: Array
  field :notes, type: String

  %w[admin event_manager unsubscribed hide_membership receive_feedback sent_welcome sent_monthly_donation_welcome].each do |b|
    field b.to_sym, type: Boolean
  end

  after_save :clear_cache
  after_destroy :clear_cache
  def clear_cache
    Fragment.and(key: "/organisations/carousel/#{account_id}").destroy_all
  end

  def api_hash
    {
      id: id.to_s,
      name: account.name,
      firstname: account.firstname,
      lastname: account.lastname,
      email: account.email,
      created_at: created_at.iso8601
    }
  end

  # Geocoder
  geocoded_by :monthly_donation_postcode

  def lat
    coordinates[1] if coordinates
  end

  def lng
    coordinates[0] if coordinates
  end
  after_validation do
    if monthly_donation_postcode_changed?
      if monthly_donation_postcode
        geocode || (self.coordinates = nil)
      else
        self.coordinates = nil
      end
    end
  end

  has_many :creditings, dependent: :destroy

  def credit_granted(description_hash: false)
    credits = []
    creditings.each do |crediting|
      credits << [Money.new(crediting.amount * 100, crediting.currency), "on #{crediting.created_at} by #{crediting.account.name}"]
    end
    account.orders_as_affiliate.and(:payment_completed => true, :event_id.in => organisation.events.pluck(:id), :account_id.ne => account.id).each do |order|
      credits << [Money.new(order.event.organisation&.affiliate_credit_percentage.to_f / 100 * (order.value || 0) * 100, order.currency), "for #{order.account ? order.account.name : 'deleted account'}'s order to #{order.event.name} at #{order.created_at}"] if order.event.organisation&.affiliate_credit_percentage
    end
    if description_hash
      credits.map { |c| [c[0].exchange_to(organisation.currency).format, c[1]] }
    else
      r = Money.new(0, organisation.currency)
      credits.each { |c| r += c[0] }
      r
    end
  end

  def credit_used(description_hash: false)
    credits = []
    account.orders.and(:event_id.in => organisation.events.pluck(:id)).and(:credit_applied.ne => nil).each do |order|
      credits << [Money.new(order.credit_applied * 100, order.currency), "on #{order.event.name} at #{order.created_at}"]
    end
    if description_hash
      credits.map { |c| [c[0].exchange_to(organisation.currency).format, c[1]] }
    else
      r = Money.new(0, organisation.currency)
      credits.each { |c| r += c[0] }
      r
    end
  end

  def credit_balance
    credit_granted - credit_used
  end

  attr_accessor :skip_welcome

  def associate_with_relevant_local_groups!
    return unless account.coordinates

    relevant_local_groups.each { |local_group| local_group.local_groupships.find_or_create_by(account: account).set(unsubscribed: false) }
  end

  def relevant_local_groups
    organisation.local_groups.geo_spatial(:polygons.intersects_point => account.coordinates)
  end

  after_create do
    account.set(organisation_ids_cache: ((account.organisation_ids_cache || []) + [organisation.id]).uniq)
    # Update account's subscribed/unsubscribed organisation caches
    if unsubscribed
      account.set(unsubscribed_organisation_ids_cache: ((account.unsubscribed_organisation_ids_cache || []) + [organisation.id]).uniq)
    else
      account.set(subscribed_organisation_ids_cache: ((account.subscribed_organisation_ids_cache || []) + [organisation.id]).uniq)
      associate_with_relevant_local_groups!
    end
    # Refresh organisations IDs in notification cache
    account.account_notification_cache&.refresh_organisations_ids!
    send_welcome unless skip_welcome
  end

  after_destroy do
    account&.rebuild_organisation_caches!
  end

  after_save do
    if hide_membership
      account.set(organisation_ids_public_cache: (account.organisation_ids_public_cache || []) - [organisation.id])
    else
      account.set(organisation_ids_public_cache: ((account.organisation_ids_public_cache || []) + [organisation.id]).uniq)
    end
    # Update account's subscribed/unsubscribed organisation caches when unsubscribed status changes
    if saved_change_to_unsubscribed?
      if unsubscribed
        account.set(subscribed_organisation_ids_cache: (account.subscribed_organisation_ids_cache || []) - [organisation.id])
        account.set(unsubscribed_organisation_ids_cache: ((account.unsubscribed_organisation_ids_cache || []) + [organisation.id]).uniq)
      else
        account.set(unsubscribed_organisation_ids_cache: (account.unsubscribed_organisation_ids_cache || []) - [organisation.id])
        account.set(subscribed_organisation_ids_cache: ((account.subscribed_organisation_ids_cache || []) + [organisation.id]).uniq)
      end
    end
    send_monthly_donation_welcome if monthly_donation_method && !sent_monthly_donation_welcome
  end

  def send_welcome(force: false)
    return unless organisation.mailgun_api_key
    return if sent_welcome && !force
    return unless organisation.welcome_from && organisation.welcome_subject

    mg_client = Mailgun::Client.new organisation.mailgun_api_key, (organisation.mailgun_region == 'EU' ? 'api.eu.mailgun.net' : 'api.mailgun.net')
    batch_message = Mailgun::BatchMessage.new(mg_client, organisation.mailgun_domain)

    account = self.account
    header = if organisation.image
               %(
      <div style="text-align: center">
          <a href="#{organisation.website || "#{ENV['BASE_URI']}/o/#{organisation.slug}"}">
            <img src="#{organisation.image.url}" style="max-width: 100px; padding-top: 16px">
          </a>
      </div>
    )
             else
               ''
             end
    content = %(
    #{header}
    <div class="main">
      #{EmailHelper.replace_youtube_oembeds(organisation.welcome_body)}
    </div>)
    batch_message.from organisation.welcome_from
    batch_message.subject organisation.welcome_subject
    batch_message.body_html EmailHelper.html(content: content)

    batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token_for_email, 'id' => account.id.to_s })

    batch_message.finalize if organisation.mailgun_api_key
    set(sent_welcome: true)
  end

  def monthly_donation_welcome_body
    b = organisation.monthly_donation_welcome_body.clone
    b.scan(%r{(<p>(\[(\d+)-(\d+)\] )(.*?)</p>)}).each do |r|
      if monthly_donation_amount && monthly_donation_amount >= r[2].to_i && monthly_donation_amount < r[3].to_i
        b.gsub!(r[0], "<p>#{r[4]}</p>")
      else
        b.gsub!(r[0], '')
      end
    end
    b.scan(%r{(<p>(\[(\d+)\+\] )(.*?)</p>)}).each do |r|
      if monthly_donation_amount && monthly_donation_amount >= r[2].to_i
        b.gsub!(r[0], "<p>#{r[3]}</p>")
      else
        b.gsub!(r[0], '')
      end
    end
    b
  end

  def send_monthly_donation_welcome(force: false)
    return unless organisation.mailgun_api_key
    return if sent_monthly_donation_welcome && !force
    return unless organisation.monthly_donation_welcome_from && organisation.monthly_donation_welcome_subject

    mg_client = Mailgun::Client.new organisation.mailgun_api_key, (organisation.mailgun_region == 'EU' ? 'api.eu.mailgun.net' : 'api.mailgun.net')
    batch_message = Mailgun::BatchMessage.new(mg_client, organisation.mailgun_domain)

    account = self.account
    header = if organisation.image
               %(
      <div style="text-align: center">
          <a href="#{organisation.website || "#{ENV['BASE_URI']}/o/#{organisation.slug}"}">
            <img src="#{organisation.image.url}" style="max-width: 100px; padding-top: 16px">
          </a>
      </div>
    )
             else
               ''
             end
    content = %(
    #{header}
    <div class="main">
      #{EmailHelper.replace_youtube_oembeds(monthly_donation_welcome_body)}
    </div>)
    batch_message.from organisation.monthly_donation_welcome_from
    batch_message.subject organisation.monthly_donation_welcome_subject
    batch_message.body_html EmailHelper.html(content: content)

    batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token_for_email, 'id' => account.id.to_s, 'username' => account.username })

    batch_message.finalize if organisation.mailgun_api_key
    set(sent_monthly_donation_welcome: true)
  end

  validates_uniqueness_of :account, scope: :organisation

  before_validation do
    if monthly_donation_amount.nil?
      self.monthly_donation_method = nil
      self.monthly_donation_currency = nil
      self.monthly_donation_start_date = nil
      self.monthly_donation_postcode = nil
    end
  end

  def stripe_user_id
    return unless stripe_connect_json

    JSON.parse(stripe_connect_json)['stripe_user_id']
  end

  def stripe_account_name
    return unless stripe_account_json

    j = JSON.parse(stripe_account_json)
    j.dig('business_profile', 'name') ||
      j.dig('settings', 'dashboard', 'display_name') ||
      j['display_name']
  end

  def monthly_donor?
    monthly_donation_method
  end

  def set_unsubscribed!(value)
    return if unsubscribed == value

    set(unsubscribed: value)
    if value
      account.set(subscribed_organisation_ids_cache: (account.subscribed_organisation_ids_cache || []) - [organisation.id])
      account.set(unsubscribed_organisation_ids_cache: ((account.unsubscribed_organisation_ids_cache || []) + [organisation.id]).uniq)
    else
      account.set(unsubscribed_organisation_ids_cache: (account.unsubscribed_organisation_ids_cache || []) - [organisation.id])
      account.set(subscribed_organisation_ids_cache: ((account.subscribed_organisation_ids_cache || []) + [organisation.id]).uniq)
      associate_with_relevant_local_groups!
    end
  end

  def organisation_tier
    organisation_tier = nil
    organisation.organisation_tiers.order('threshold asc').each do |ot|
      organisation_tier = ot if monthly_donation_amount && monthly_donation_currency && Money.new(monthly_donation_amount * 100, monthly_donation_currency) >= Money.new(ot.threshold * 100, organisation.currency)
    end
    organisation_tier
  end

  def monthly_donor_discount
    organisation_tier.try(:discount) || 0
  end

  def absorb_duplicate!(victim)
    set(admin: true) if victim.admin
    set(event_manager: true) if victim.event_manager

    attrs = {}
    attrs['notes'] = victim.notes if notes.blank? && victim.notes.present?

    if stripe_connect_json.blank? && victim.stripe_connect_json.present?
      attrs['stripe_connect_json'] = victim.stripe_connect_json
      attrs['stripe_account_json'] = victim.stripe_account_json
    end

    if monthly_donation_method.blank? && victim.monthly_donation_method.present?
      %w[
        monthly_donation_method monthly_donation_amount monthly_donation_currency
        monthly_donation_start_date monthly_donation_postcode monthly_donation_annual
        coordinates sent_monthly_donation_welcome
      ].each do |field|
        attrs[field] = victim[field]
      end
    end

    set(attrs) if attrs.any?
    Crediting.and(organisationship_id: victim.id).update_all(organisationship_id: id)
  end

  def self.dedupe_duplicates!(account: nil, preferred_ids: [])
    pipeline = []
    pipeline << { '$match' => { 'account_id' => account.id } } if account
    pipeline += [
      { '$group' => { '_id' => { 'account_id' => '$account_id', 'organisation_id' => '$organisation_id' }, 'ids' => { '$push' => '$_id' }, 'count' => { '$sum' => 1 } } },
      { '$match' => { 'count' => { '$gt' => 1 } } }
    ]
    collection.aggregate(pipeline).each do |group|
      records = self.and(:id.in => group['ids']).order('created_at asc').to_a
      survivor = records.find { |record| preferred_ids.include?(record.id) } || records.first
      records.delete(survivor)
      records.each do |victim|
        survivor.absorb_duplicate!(victim)
        victim.destroy
      end
    end
  end

  def self.protected_attributes
    %w[admin event_manager]
  end

  def self.monthly_donation_methods
    [''] + %w[GoCardless Patreon PayPal Other]
  end
end
