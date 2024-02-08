class Organisationship
  include Mongoid::Document
  include Mongoid::Timestamps
  include Geocoder::Model::Mongoid

  belongs_to :organisation, index: true
  belongs_to :account, inverse_of: :organisationships, index: true
  belongs_to :referrer, class_name: 'Account', inverse_of: :organisationships_as_referrer, index: true, optional: true

  field :stripe_connect_json, type: String
  field :stripe_account_json, type: String
  field :monthly_donation_method, type: String
  field :monthly_donation_amount, type: Float
  field :monthly_donation_currency, type: String
  field :monthly_donation_start_date, type: Date
  field :monthly_donation_postcode, type: String
  field :coordinates, type: Array
  field :why_i_joined, type: String
  field :why_i_joined_edited, type: String
  field :notes, type: String

  %w[admin unsubscribed subscribed_discussion hide_membership receive_feedback why_i_joined_public sent_welcome sent_monthly_donation_welcome hide_referrer].each do |b|
    field b.to_sym, type: Boolean
    index({ b.to_s => 1 })
  end
  index({ monthly_donation_method: 1 })

  after_save :clear_cache
  after_destroy :clear_cache
  def clear_cache
    Fragment.and(key: %r{/organisations/carousel/#{account_id}}).destroy_all
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

  def self.marker_color
    '#00B963'
  end

  def self.marker_icon
    'fa fa-user'
  end

  def self.admin_fields
    {
      account_id: :lookup,
      organisation_id: :lookup,
      referrer_id: :lookup,
      admin: :check_box,
      unsubscribed: :check_box,
      subscribed_discussion: :check_box,
      receive_feedback: :check_box,
      hide_membership: :check_box,
      sent_monthly_donation_welcome: :check_box,
      hide_referrer: :check_box,
      stripe_connect_json: :text_area,
      stripe_account_json: :text_area,
      monthly_donation_amount: :number,
      monthly_donation_currency: :text,
      monthly_donation_method: :select,
      monthly_donation_start_date: :date,
      monthly_donation_postcode: :text,
      why_i_joined: :text_area,
      why_i_joined_public: :check_box,
      why_i_joined_edited: :text_area
    }
  end

  has_many :creditings, dependent: :destroy

  def credit_granted(description_hash: false)
    credits = []
    creditings.each do |crediting|
      credits << [Money.new(crediting.amount * 100, crediting.currency), "on #{crediting.created_at} by #{crediting.account.name}"]
    end
    account.orders_as_affiliate.and(:payment_completed => true, :event_id.in => organisation.events.pluck(:id)).each do |order|
      credits << [Money.new(order.event.affiliate_credit_percentage.to_f / 100 * (order.value || 0) * 100, order.currency), "for #{order.account ? order.account.name : 'deleted account'}'s order to #{order.event.name} at #{order.created_at}"] if order.event.affiliate_credit_percentage
    end
    if organisation.monthly_donor_affiliate_reward && monthly_donor?
      if referrer && (referrer_organisationship = organisation.organisationships.find_by(account: referrer)) && referrer_organisationship.monthly_donor?
        credits << [Money.new(organisation.monthly_donor_affiliate_reward * 100, organisation.currency), "for being referred by @#{referrer.username}"]
      end
      account.organisationships_as_referrer.and(organisation: organisation).each do |organisationship|
        credits << [Money.new(organisation.monthly_donor_affiliate_reward * 100, organisation.currency), "for referring @#{organisationship.account.username}"] if organisationship.monthly_donor?
      end
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

  after_create do
    relevant_local_groups.each { |local_group| local_group.local_groupships.create account: account } if account.coordinates
    account.update_attribute(:organisation_ids_cache, ((account.organisation_ids_cache || []) + [organisation.id]).uniq)
  end

  def relevant_local_groups
    organisation.local_groups.geo_spacial(:polygons.intersects_point => account.coordinates)
  end

  after_create do
    send_welcome unless skip_welcome
  end

  after_save do
    if hide_membership
      account.update_attribute(:organisation_ids_public_cache, (account.organisation_ids_public_cache || []) - [organisation.id])
    else
      account.update_attribute(:organisation_ids_public_cache, ((account.organisation_ids_public_cache || []) + [organisation.id]).uniq)
    end
    send_monthly_donation_welcome if monthly_donation_method && !sent_monthly_donation_welcome
  end

  def send_welcome(force: false)
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
      #{organisation.welcome_body}
    </div>)
    batch_message.from organisation.welcome_from
    batch_message.subject organisation.welcome_subject
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    [account].each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => (account.firstname || 'there'), 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

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
      #{monthly_donation_welcome_body}
    </div>)
    batch_message.from organisation.monthly_donation_welcome_from
    batch_message.subject organisation.monthly_donation_welcome_subject
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    [account].each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => (account.firstname || 'there'), 'token' => account.sign_in_token, 'id' => account.id.to_s, 'username' => account.username })
    end

    batch_message.finalize if organisation.mailgun_api_key
    set(sent_monthly_donation_welcome: true)
  end

  after_destroy do
    account.update_attribute(:organisation_ids_cache, (account.organisation_ids_cache || []) - [organisation.id])
    account.update_attribute(:organisation_ids_public_cache, (account.organisation_ids_public_cache || []) - [organisation.id])
  end

  validates_uniqueness_of :account, scope: :organisation

  before_validation do
    errors.add(:referrer, 'cannot be the same as account') if referrer && account && referrer_id == account_id
    self.referrer = nil if hide_referrer
    self.hide_referrer = nil if referrer
  end

  def stripe_user_id
    JSON.parse(stripe_connect_json)['stripe_user_id']
  end

  def stripe_account_name
    return unless stripe_account_json

    j = JSON.parse(stripe_account_json)
    if j['business_profile'] && j['business_profile']['name']
      j['business_profile']['name']
    else
      j['display_name']
    end
  end

  def monthly_donor?
    monthly_donation_method
  end

  def organisation_tier
    organisation_tier = nil
    organisation.organisation_tiers.order('threshold asc').each do |ot|
      organisation_tier = ot if Money.new(monthly_donation_amount * 100, monthly_donation_currency) >= Money.new(ot.threshold * 100, organisation.currency)
    end
    organisation_tier
  end

  def monthly_donor_discount
    organisation_tier.try(:discount) || 0
  end

  def self.protected_attributes
    %w[admin]
  end

  def self.monthly_donation_methods
    [''] + %w[GoCardless Patreon PayPal Other]
  end
end
