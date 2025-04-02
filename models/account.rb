class Account
  include Mongoid::Document
  include Mongoid::Timestamps
  extend Dragonfly::Model

  dragonfly_accessor :image

  include AccountFields
  include AccountAssociations
  include AccountValidation
  include AccountNotifications
  include AccountFeedbackSummaries
  include AccountFarcaster
  include AccountRecommendations
  include Geocoded

  def self.fu(username)
    Account.find_by(username: username)
  end

  def self.public
    self.and(:sign_ins_count.gt => 0, :hidden.ne => true)
  end

  def self.sensitive?(privacyable)
    true if privacyable.in?(%i[organisations local_groups activities gatherings])
  end

  def self.protected_attributes
    %w[admin]
  end

  def self.default_currencies
    [''] + CURRENCY_OPTIONS
  end

  def self.ids_by_next_birthday
    today = Date.today
    self.and(:hidden.ne => true, :date_of_birth.ne => nil).pluck(:id, :date_of_birth)
        .sort_by { |_, dob| (((dob.month * 100) + dob.day) - ((today.month * 100) + today.day)) % (12 * 100) }
        .map { |id, _| id }
  end

  def self.recommendable
    Account.and(:id.in => Ticket.pluck(:account_id) + EventFacilitation.pluck(:account_id))
  end

  def self.generate_sign_in_token
    SecureRandom.uuid.delete('-')
  end

  def calculate_tokens
    orders.and(:value.ne => nil, :currency.in => MAJOR_CURRENCIES).sum { |o| Math.sqrt(Money.new(o.value * 100, o.currency).exchange_to('GBP').cents) } +
      Order.and(:event_id.in => events_revenue_sharing.pluck(:id), :value.ne => nil, :currency.in => MAJOR_CURRENCIES).sum { |o| 0.25 * Math.sqrt(Money.new(o.value * 100, o.currency).exchange_to('GBP').cents) } +
      payments.and(:amount.ne => nil, :currency.in => MAJOR_CURRENCIES).sum { |p| 2 * Math.sqrt(Money.new(p.amount * 100, p.currency).exchange_to('GBP').cents) } +
      account_contributions.and(:amount.ne => nil, :currency.in => MAJOR_CURRENCIES).sum { |p| Math.sqrt(Money.new(p.amount * 100, p.currency).exchange_to('GBP').cents) }
  end

  def public?
    sign_ins_count > 0 && !hidden?
  end

  def private?
    !public?
  end

  def live_player?
    [account_contributions, tickets, event_facilitations, organisationships, activityships, local_groupships, memberships].any? { |x| x.count.positive? }
  end

  def able_to_message
    email_confirmed && (can_message || live_player?)
  end

  def open_to
    o = Account.open_to.select { |x| send("open_to_#{x}") }
    o.empty? ? nil : o
  end

  def image_thumb_or_gravatar_url
    if image
      image.thumb('400x400#').url
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

  def next_birthday
    return unless date_of_birth

    now = Date.today
    next_birthday = Date.new(now.year, date_of_birth.month, date_of_birth.day)
    next_birthday = Date.new(now.year + 1, date_of_birth.month, date_of_birth.day) if now > next_birthday

    next_birthday
  rescue StandardError
    nil
  end

  def days_until_next_birthday
    return unless next_birthday

    now = Date.today
    (next_birthday - now).to_i
  end

  def age
    return unless (dob = date_of_birth)

    now = Time.now.utc.to_date
    now.year - dob.year - (now.month > dob.month || (now.month == dob.month && now.day >= dob.day) ? 0 : 1)
  end

  def firstname
    return if name.blank?

    parts = name.split
    n = if parts.count > 1 && %w[mr mrs ms dr].include?(parts[0].downcase.gsub('.', ''))
          parts[1]
        else
          parts[0]
        end
    n.capitalize
  end

  def lastname
    return unless name

    nameparts = name.split
    nameparts[1..].join(' ') if nameparts.length > 1
  end

  def abbrname
    return unless firstname

    firstname.capitalize + (lastname ? " #{lastname[0].upcase}." : '')
  end

  def uid
    id
  end

  def info
    { email: email, name: name }
  end

  after_create do
    notifications_as_notifiable.create! circle: self, type: 'created_profile'
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

  def self.authenticate(email, password)
    return unless email.present? && (account = find_by(email: email.downcase))

    if account.failed_sign_in_attempts && account.failed_sign_in_attempts >= 99
      nil
    elsif account.password_matches?(password)
      account.update_attribute(:failed_sign_in_attempts, 0)
      account
    else
      account.update_attribute(:failed_sign_in_attempts, (account.failed_sign_in_attempts || 0) + 1)
      nil
    end
  end

  before_save :encrypt_password, if: :password_required

  def password_matches?(password)
    ::BCrypt::Password.new(crypted_password) == password
  end

  def self.generate_password
    chars = ('a'..'z').to_a + ('0'..'9').to_a
    Array.new(16) { chars[rand(chars.size)] }.join
  end

  private

  def encrypt_password
    self.crypted_password = ::BCrypt::Password.create(password)
  end

  def password_required
    crypted_password.blank? || password.present?
  end
end
