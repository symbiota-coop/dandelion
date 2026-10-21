class Account
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  extend Dragonfly::Model
  include AccountFields
  include ImageWithValidation
  include AccountAssociations
  include AccountValidation
  include AccountNotifications
  include FeedbackSummaries
  include AccountRecommendations
  include AccountAtproto
  include AccountStripeSubscriptions
  include Geocoded
  include Searchable

  def self.fu(username)
    Account.find_by(username: username)
  end

  def self.prewarmed_image_derivative_sizes
    %w[400x400#]
  end

  def self.search_fields
    %w[name name_transliterated email username]
  end

  def self.search_scope
    publicly_visible
  end

  def self.publicly_visible
    self.and(has_signed_in: true, hidden: false)
  end

  def self.feedback_summaries_scope
    Account.and(:id.in => EventFacilitation.and(:event_id.in => Event.past.pluck(:id)).pluck(:account_id))
  end

  def feedback_summaries_source
    event_feedbacks_as_facilitator
  end

  def feedback_summary_log_label
    username
  end

  def feedback_summary_prompt
    "Provide a one-paragraph summary of the feedback on this facilitator, #{name}. Focus on their strengths and what they do well. The feedback:\n\n#{event_feedbacks_as_facilitator.joined}"
  end

  def self.sensitive?(privacyable)
    true if privacyable.in?(%i[organisations local_groups activities gatherings])
  end

  def api_hash
    {
      id: id.to_s,
      name: name,
      username: username,
      email: email,
      url: "#{ENV['BASE_URI']}/u/#{username}"
    }
  end

  def self.permitted_attributes
    %w[
      name username email image remove_image location phone website
      postcode country
      date_of_birth gender bio dietary_requirements
      default_currency
      hidden
      unsubscribed unsubscribed_messages unsubscribed_feedback unsubscribed_reminders
      updated_profile
    ]
  end

  def self.subscription_attributes
    %w[unsubscribed unsubscribed_messages unsubscribed_feedback unsubscribed_reminders]
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
    Account.and('$or' => [
      { :id.in => Ticket.distinct(:account_id).compact },
      { :id.in => EventFacilitation.distinct(:account_id).compact },
      { :id.in => Membership.distinct(:account_id).compact }
    ]).and(:last_active.gt => 1.year.ago)
  end

  # The time it was made in base 36, padded to 7 characters, then 16 random letters and digits
  def self.generate_link_token
    "#{Time.now.to_i.to_s(36).rjust(7, '0')}#{SecureRandom.alphanumeric(16)}"
  end

  def ensure_ics_key!
    return ics_key if ics_key.present?

    set(ics_key: SecureRandom.uuid)
    ics_key
  end

  def generate_link_token
    self.link_token = Account.generate_link_token
  end

  def generate_link_token!
    set(link_token: Account.generate_link_token)
  end

  def link_token_for_email
    return link_token unless link_token_expired?

    generate_link_token!
    link_token
  end

  # A sign in code is emailed only when someone asks for one, unlike link_token, which is in the links of every email,
  # so signing in with one shows they get this address's email now (recently_verified?). It lasts an hour and works once,
  # and only its digest is stored. Indexes: sign_in_code_digest_1_unique and sign_in_code_digest_1
  SIGN_IN_CODE_LIFETIME = 1.hour
  # Anyone can ask for an account's code, so asking again resends the code already sent rather than ending it, until it has
  # this long left. The code is made from sign_in_code_nonce and TokenVerifier's secret, so the database alone can't give it
  SIGN_IN_CODE_REUSABLE_FOR = 15.minutes

  def issue_sign_in_code!
    if sign_in_code_nonce && sign_in_code_expires_at && sign_in_code_expires_at > SIGN_IN_CODE_REUSABLE_FOR.from_now
      code = Account.sign_in_code_from_nonce(sign_in_code_nonce)
      # Unless the secret has changed since
      return code if code && Account.sign_in_code_digest(code) == sign_in_code_digest
    end

    nonce = SecureRandom.hex(16)
    code = Account.sign_in_code_from_nonce(nonce) || SecureRandom.alphanumeric(20)
    set(sign_in_code_digest: Account.sign_in_code_digest(code), sign_in_code_nonce: nonce, sign_in_code_expires_at: SIGN_IN_CODE_LIFETIME.from_now)
    code
  end

  # 20 base 36 characters, or nil without the secret, when each code is random and asking again ends the last one
  def self.sign_in_code_from_nonce(nonce)
    return unless (secret = TokenVerifier.secret)

    OpenSSL::HMAC.hexdigest('SHA256', secret, "sign_in_code:#{nonce}").to_i(16).to_s(36)[0, 20]
  end

  def self.sign_in_code_digest(code)
    OpenSSL::Digest::SHA256.hexdigest(code.to_s)
  end

  def self.with_sign_in_code(code)
    return if code.blank?

    self.and(sign_in_code_digest: sign_in_code_digest(code), :sign_in_code_expires_at.gt => Time.now).first
  end

  # False if another request used the code first
  def redeem_sign_in_code!(code)
    Account.and(id: id, sign_in_code_digest: Account.sign_in_code_digest(code))
           .update_all('$unset' => { sign_in_code_digest: true, sign_in_code_nonce: true, sign_in_code_expires_at: true }).modified_count == 1
  end

  # Each session carries the token it was started with (start_session!), so changing it signs out every browser
  def session_token!
    return session_token if session_token

    # Only if still unset, so two requests at once can't each set one and leave the other's session holding a stale token
    Account.and(id: id, session_token: nil).update_all(session_token: SecureRandom.uuid)
    attributes['session_token'] = Account.and(id: id).pluck(:session_token).first # already saved, so not a pending change
  end

  # Signs out every browser, and ends the links and code already sent, which would otherwise sign one back in. It leaves the
  # API key and calendar feed key, which integrations and calendar apps hold: only a session that entered a code sees
  # them (/accounts/api_key), and its owner can replace them there
  def revoke_sessions!
    end_sessions!
    generate_link_token!
    unset(:sign_in_code_digest, :sign_in_code_nonce, :sign_in_code_expires_at)
  end

  # Changes the session token, which signs out every browser
  def end_sessions!
    set(session_token: SecureRandom.uuid, legacy_sessions_revoked: true)
  end

  # Whoever set up an account whose email isn't confirmed may not own the address (signing up with someone else's email,
  # say, so their guest tickets go on it), so the first time someone signs in from a link in its email, in a browser that
  # didn't set it up, other browsers are signed out (sign_in_from_email). Only the first time, so mail scanners opening
  # links can't keep signing out the person who set it up. It leaves the links and code already sent, which only the
  # email's owner has
  def end_sessions_for_first_email_sign_in!
    return unless Account.and(id: id, :ended_sessions_for_email_sign_in.ne => true).update_all('$set' => { ended_sessions_for_email_sign_in: true }).modified_count == 1

    end_sessions!
  end

  def replace_api_key!
    set(api_key: SecureRandom.uuid)
  end

  def replace_ics_key!
    set(ics_key: SecureRandom.uuid)
  end

  # Someone has shown they get this address's email. Whoever set the account up may not have been them, so unless they
  # did it in this browser, other sessions end, the password, API key and calendar feed key are replaced and providers
  # connected before now are removed. Returns the removed providers
  def confirm_email!(same_browser:)
    set(email_confirmed: true)
    # Links from before before_email_confirmed have no value for it, and could have been connected by anyone
    unconfirmed_links = provider_links.and('$or' => [{ before_email_confirmed: true }, { before_email_confirmed: nil }])
    if same_browser
      unconfirmed_links.update_all(before_email_confirmed: false)
      []
    else
      revoke_sessions!
      replace_api_key!
      replace_ics_key!
      set(crypted_password: ::BCrypt::Password.create(Account.generate_password, cost: ::BCrypt::Engine::MIN_COST)) # nobody is given it
      unconfirmed_links.pluck(:provider).tap { unconfirmed_links.destroy_all }
    end
  end

  # The new address is unconfirmed (AccountValidation), and its owner may not be whoever connected the providers, so
  # they're treated as connected before it was confirmed: confirm_email! keeps them only if it's confirmed in a browser
  # that set the account up
  after_save do
    provider_links.update_all(before_email_confirmed: true) if previous_changes['email'] && previous_changes['email'][0]
  end

  def link_token_expired?
    Account.link_token_expired?(link_token)
  end

  def self.link_token_expired?(token)
    return true if token.blank?

    # Tokens made before 11 Oct 2026 are timestamp-hex. Drop this branch once they have all expired
    timestamp = if token.include?('-')
                  token.split('-', 2).first.to_i
                else
                  token[0, 7].to_i(36)
                end
    return true if timestamp.zero?

    (Time.now.to_i - timestamp) > 24.hours.to_i
  end

  def feedback_token_for(event)
    return unless event

    TokenVerifier.generate("feedback:#{event.id}:#{id}")
  end

  def self.from_feedback_token(event, token)
    return unless event

    data = TokenVerifier.verify(token)

    return unless data

    prefix, event_id, account_id = data.split(':', 3)
    return unless prefix == 'feedback' && event_id == event.id.to_s

    find_by(id: account_id)
  end

  def organisation_unsubscribe_token_for(organisation)
    return unless organisation

    TokenVerifier.generate("org_unsubscribe:#{organisation.id}:#{id}")
  end

  def self.from_organisation_unsubscribe_token(organisation, token)
    return unless organisation

    data = TokenVerifier.verify(token)
    return unless data

    prefix, org_id, account_id = data.split(':', 3)
    return unless prefix == 'org_unsubscribe' && org_id == organisation.id.to_s

    find_by(id: account_id)
  end

  def merge(victim)
    return if id == victim.id

    preferred_organisationship_ids = organisationships.pluck(:id)

    # Transfer all has_many associations using reflection
    self.class.reflect_on_all_associations(:has_many).each do |association|
      foreign_key = association.foreign_key

      # Handle associations with different naming patterns
      if association.options[:inverse_of]
        foreign_key = "#{association.options[:inverse_of]}_id"
      elsif association.options[:as]
        # For polymorphic associations
        type_key = "#{association.options[:as]}_type"
        id_key = "#{association.options[:as]}_id"

        klass = association.klass
        if klass.respond_to?(:unscoped)
          klass.unscoped.and(type_key => victim.class.name, id_key => victim.id)
               .update_all(id_key => id)
        end
        next
      end

      target_collection = victim.send(association.name)
      target_collection.update_all(foreign_key => id) if target_collection.respond_to?(:update_all)
    end

    Organisationship.dedupe_duplicates!(account: self, preferred_ids: preferred_organisationship_ids)
    rebuild_organisation_caches!

    # Reload so dependent: :destroy does not delete associations already transferred
    victim.reload
    victim.destroy

    # Return self for method chaining
    self
  end

  def rebuild_organisation_caches!
    rels = organisationships
    set(
      organisation_ids_cache: rels.pluck(:organisation_id).uniq,
      organisation_ids_public_cache: rels.and(:hide_membership.ne => true).pluck(:organisation_id).uniq,
      subscribed_organisation_ids_cache: rels.and(:unsubscribed.ne => true).pluck(:organisation_id).uniq,
      unsubscribed_organisation_ids_cache: rels.and(unsubscribed: true).pluck(:organisation_id).uniq
    )
    account_notification_cache&.refresh_organisations_ids!
  end

  def publicly_visible?
    has_signed_in && !hidden?
  end

  def private?
    !publicly_visible?
  end

  def live_player?
    [account_contributions, tickets, event_facilitations, organisationships, activityships, local_groupships, memberships].any? { |x| x.count.positive? }
  end

  def able_to_message
    return false if blocked_from_messaging

    email_confirmed && (can_message || live_player?)
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
    # Addressable leaves the fallback's : and / alone, as views escape this URL again with u (so % would become %25)
    Padrino.env == :development ? generated_avatar_path : "https://www.gravatar.com/avatar/#{Digest::MD5.hexdigest(email.downcase)}?s=400&d=#{Addressable::URI.escape("#{ENV['BASE_URI']}#{generated_avatar_path}")}"
  end

  # For the <img> of an account's image or Gravatar: the generated avatar is a stencil (lib/generated_avatar.rb),
  # which takes the theme colour from avatar-initials' background. Photos are opaque, so it doesn't show behind them
  def avatar_class
    'avatar-initials' unless image
  end

  # Unescaped (an accented initial stays as it is), as gravatar_url and the views escape it
  def generated_avatar_path
    initials = GeneratedAvatar.initials(name)
    initials ? "/avatar/v2/#{initials}.png" : '/avatar/v2.png'
  end

  def unread_notifications?(notifications = network_notifications)
    (n = notifications.order('created_at desc').first) && (!last_checked_notifications || (n.created_at > last_checked_notifications))
  end

  def unchecked_messages?
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
    return unless email.present? && (account = find_by(email: email.downcase.strip))

    if account.failed_sign_in_attempts && account.failed_sign_in_attempts >= 99
      nil
    elsif account.password_matches?(password)
      account.set(failed_sign_in_attempts: 0)
      account
    else
      account.inc(failed_sign_in_attempts: 1)
      nil
    end
  end

  before_save :encrypt_password, if: :password_required

  def password_matches?(password)
    ::BCrypt::Password.new(crypted_password) == password
  end

  def self.generate_password(length = 16)
    chars = ('a'..'z').to_a + ('0'..'9').to_a
    Array.new(length) { chars[SecureRandom.random_number(chars.size)] }.join
  end

  # A random adjective_noun, numbered (_1, _2...) when taken. There are only 64 × 64 of them, so most are taken
  # several times over: one anchored prefix query (which uses the username index) gets every taken variant,
  # rather than a query per number tried
  def self.generate_username
    base = Haikunator.haikunate(0).underscore
    taken = Account.and(username: /\A#{Regexp.escape(base)}(_\d+)?\z/).pluck(:username).to_set
    return base unless taken.include?(base)

    n = 1
    n += 1 while taken.include?("#{base}_#{n}")
    "#{base}_#{n}"
  end

  def self.check_organisation_cache_sync(fix: false)
    out_of_sync = []

    # Single aggregation to compute expected caches for all accounts at once
    expected_caches = Organisationship.collection.aggregate([
                                                              {
                                                                '$group' => {
                                                                  '_id' => '$account_id',
                                                                  'org_ids' => { '$push' => '$organisation_id' },
                                                                  'public_ids' => {
                                                                    '$push' => {
                                                                      '$cond' => [{ '$ne' => ['$hide_membership', true] }, '$organisation_id', '$$REMOVE']
                                                                    }
                                                                  },
                                                                  'subscribed_ids' => {
                                                                    '$push' => {
                                                                      '$cond' => [{ '$ne' => ['$unsubscribed', true] }, '$organisation_id', '$$REMOVE']
                                                                    }
                                                                  },
                                                                  'unsubscribed_ids' => {
                                                                    '$push' => {
                                                                      '$cond' => [{ '$eq' => ['$unsubscribed', true] }, '$organisation_id', '$$REMOVE']
                                                                    }
                                                                  }
                                                                }
                                                              }
                                                            ]).to_a.to_h { |doc| [doc['_id'], doc] }

    # Get accounts that either have organisationships OR have stale cache fields
    account_ids_with_caches = Account.and('$or' => [
      { :organisation_ids_cache.ne => nil },
      { :organisation_ids_public_cache.ne => nil },
      { :subscribed_organisation_ids_cache.ne => nil },
      { :unsubscribed_organisation_ids_cache.ne => nil }
    ]).pluck(:id)

    relevant_account_ids = (expected_caches.keys + account_ids_with_caches).uniq

    relevant_account_ids.each_slice(1000) do |batch_ids|
      Account.in(id: batch_ids).each do |account|
        expected = expected_caches[account.id] || {}

        raw_org_ids = (expected['org_ids'] || []).map(&:to_s)
        expected_org_ids = raw_org_ids.uniq.sort
        expected_public_ids = (expected['public_ids'] || []).map(&:to_s).uniq.sort
        expected_subscribed_ids = (expected['subscribed_ids'] || []).map(&:to_s).uniq.sort
        expected_unsubscribed_ids = (expected['unsubscribed_ids'] || []).map(&:to_s).uniq.sort

        current_org_ids = (account.organisation_ids_cache || []).map(&:to_s).sort
        current_public_ids = (account.organisation_ids_public_cache || []).map(&:to_s).sort
        current_subscribed_ids = (account.subscribed_organisation_ids_cache || []).map(&:to_s).sort
        current_unsubscribed_ids = (account.unsubscribed_organisation_ids_cache || []).map(&:to_s).sort

        duplicates = raw_org_ids.tally.select { |_, count| count > 1 }.sort.map do |organisation_id, count|
          { organisation_id: organisation_id, count: count }
        end

        mismatches = []
        mismatches << 'organisation_ids_cache' if current_org_ids != expected_org_ids
        mismatches << 'organisation_ids_public_cache' if current_public_ids != expected_public_ids
        mismatches << 'subscribed_organisation_ids_cache' if current_subscribed_ids != expected_subscribed_ids
        mismatches << 'unsubscribed_organisation_ids_cache' if current_unsubscribed_ids != expected_unsubscribed_ids
        mismatches << 'duplicate_organisationships' if duplicates.any?

        next if mismatches.empty?

        details = {
          organisation_ids_cache: { current: current_org_ids, expected: expected_org_ids },
          organisation_ids_public_cache: { current: current_public_ids, expected: expected_public_ids },
          subscribed_organisation_ids_cache: { current: current_subscribed_ids, expected: expected_subscribed_ids },
          unsubscribed_organisation_ids_cache: { current: current_unsubscribed_ids, expected: expected_unsubscribed_ids }
        }
        if duplicates.any?
          details[:duplicate_organisationships] = {
            current: duplicates.map { |d| "#{d[:organisation_id]} (#{d[:count]} rows)" },
            expected: duplicates.map { |d| "#{d[:organisation_id]} (1 row)" }
          }
        end

        out_of_sync << {
          account: account,
          mismatches: mismatches,
          duplicates: duplicates,
          details: details
        }
      end
    end

    if fix
      Organisationship.dedupe_duplicates!
      out_of_sync.each { |entry| entry[:account].rebuild_organisation_caches! }
    end

    out_of_sync
  end

  private

  # A slow hash protects passwords people choose, which can be guessed. A generated password nobody is given
  # (see AccountValidation) is 16 random characters, which can't be guessed at any cost, so it's hashed at the
  # minimum, saving a few hundred ms on every account created at checkout. Any password someone sets or is given,
  # generated or not, is hashed at full cost
  def encrypt_password
    cost = password == @unused_password ? ::BCrypt::Engine::MIN_COST : ::BCrypt::Engine.cost
    self.crypted_password = ::BCrypt::Password.create(password, cost: cost)
  end

  def password_required
    crypted_password.blank? || password.present?
  end
end
