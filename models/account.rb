class Account
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  extend Dragonfly::Model
  include AccountFields
  include AccountAssociations
  include AccountValidation
  include AccountNotifications
  include AccountFeedbackSummaries
  include AccountRecommendations
  include AccountAtproto
  include Geocoded
  include Searchable

  def self.fu(username)
    Account.find_by(username: username)
  end

  def self.search_fields
    %w[name name_transliterated email username]
  end

  def self.publicly_visible
    self.and(has_signed_in: true, hidden: false)
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
    self.and(:hidden => false, :date_of_birth.ne => nil).pluck(:id, :date_of_birth)
        .sort_by { |_, dob| (((dob.month * 100) + dob.day) - ((today.month * 100) + today.day)) % (12 * 100) }
        .map { |id, _| id }
  end

  def self.recommendable
    Account.or(
      { :id.in => Ticket.distinct(:account_id).compact },
      { :id.in => EventFacilitation.distinct(:account_id).compact },
      { :id.in => Membership.distinct(:account_id).compact }
    ).and(:last_active.gt => 1.year.ago)
  end

  def self.generate_sign_in_token
    "#{Time.now.to_i}-#{generate_password(5)}"
  end

  def generate_sign_in_token
    loop do
      token = Account.generate_sign_in_token
      break self.sign_in_token = token unless Account.and(sign_in_token: token).exists?
    end
  end

  def generate_sign_in_token!
    generate_sign_in_token
    save!
  end

  def sign_in_token_expired?
    return true if sign_in_token.blank?

    # Extract timestamp from token (format: timestamp-randomtoken)
    parts = sign_in_token.split('-', 2)
    return true if parts.length != 2

    timestamp = parts[0].to_i
    return true if timestamp.zero?

    # Check if token is older than 24 hours
    (Time.now.to_i - timestamp) > 24.hours.to_i
  end

  def merge(account_to_destroy)
    # Don't allow merging with self
    return if id == account_to_destroy.id

    # Transfer all has_many associations using reflection
    self.class.reflect_on_all_associations(:has_many).each do |association|
      foreign_key = association.foreign_key

      # Handle associations with different naming patterns
      if association.options[:inverse_of]
        # For associations with explicit inverse_of
        foreign_key = "#{association.options[:inverse_of]}_id"
      elsif association.options[:as]
        # For polymorphic associations
        type_key = "#{association.options[:as]}_type"
        id_key = "#{association.options[:as]}_id"

        # Update the polymorphic association
        klass = association.klass
        if klass.respond_to?(:unscoped)
          klass.unscoped.where(type_key => account_to_destroy.class.name, id_key => account_to_destroy.id)
               .update_all(id_key => id)
        end
        next
      end

      # Get the target collection and update foreign keys
      target_collection = account_to_destroy.send(association.name)
      target_collection.update_all(foreign_key => id) if target_collection.respond_to?(:update_all)
    end

    # Delete the other account
    account_to_destroy.destroy

    # Return self for method chaining
    self
  end

  def public?
    has_signed_in && !hidden?
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
      begin
        image.thumb('400x400#').url
      rescue StandardError, Dragonfly::Shell::CommandFailed
        gravatar_url
      end
    else
      gravatar_url
    end
  end

  def gravatar_url
    Padrino.env == :development ? '/images/silhouette.png' : "https://www.gravatar.com/avatar/#{Digest::MD5.hexdigest(email.downcase)}?s=400&d=#{Addressable::URI.escape("#{ENV['BASE_URI']}/images/silhouette.png")}"
  end

  def unread_notifications?(notifications = network_notifications)
    (n = notifications.order('created_at desc').first) && (!last_checked_notifications || (n.created_at > last_checked_notifications))
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

  before_destroy do
    throw :abort if admin
  end

  after_create do
    notifications_as_notifiable.create! circle: self, type: 'created_profile'
  end

  after_save do
    if location_change
      location_change.each do |l|
        if l
          accounts = Account.and(location: location)
          accounts.update_all(number_at_this_location: accounts.count)
        end
      end
    end
  end

  def self.authenticate(email, password)
    return unless email.present? && (account = find_by(email: email.downcase))

    if account.failed_sign_in_attempts && account.failed_sign_in_attempts >= 99
      nil
    elsif account.password_matches?(password)
      account.set(failed_sign_in_attempts: 0)
      account
    else
      account.set(failed_sign_in_attempts: (account.failed_sign_in_attempts || 0) + 1)
      nil
    end
  end

  before_save :encrypt_password, if: :password_required

  def password_matches?(password)
    ::BCrypt::Password.new(crypted_password) == password
  end

  def self.generate_password(length = 16)
    chars = ('a'..'z').to_a + ('0'..'9').to_a
    Array.new(length) { chars[rand(chars.size)] }.join
  end

  private

  def encrypt_password
    self.crypted_password = ::BCrypt::Password.create(password)
  end

  def password_required
    crypted_password.blank? || password.present?
  end
end
