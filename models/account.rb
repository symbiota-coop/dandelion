class Account
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions
  include SlugLookup

  extend Dragonfly::Model
  include AccountFields
  include ImageWithValidation
  include AccountAssociations
  include AccountValidation
  include AccountNotifications
  include FeedbackSummaries
  include AccountRecommendations
  include AccountAtproto
  include AccountAvatar
  include AccountStripeSubscriptions
  include Geocoded
  include Searchable

  def self.slug_field
    :username
  end

  def self.prewarmed_image_derivative_sizes
    %w[400x400#]
  end

  def self.search_fields
    %w[name name_transliterated email username]
  end

  # Its Atlas Search index maps name and username as autocomplete too, so searches match the start of a name's words or of a username
  # (Searchable): usernames like damp_resonance_8 are one token, so not their later words
  def self.autocomplete_fields
    %w[name username]
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
    public_event_feedbacks_as_facilitator.and(deleted_at: nil)
  end

  def feedback_summary_log_label
    username
  end

  def feedback_summary_prompt
    "Provide a one-paragraph summary of the feedback on this facilitator, #{name}. Focus on their strengths and what they do well. #{FeedbackSummaries::SUMMARY_INSTRUCTIONS} The feedback:\n\n#{feedback_summaries_source.joined}"
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
    age_shown_to_others.and(:hidden => false, :date_of_birth.ne => nil).pluck(:id, :date_of_birth)
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
  # email's owner has. True if a browser had signed in to it (it had a session token), so there may have been someone to
  # sign out: an account a guest purchase made, say, has never had a session. Then the email's owner is asked to confirm it
  # (confirm_email_prompt_owed) at each link sign in until they confirm or say not now, as the first may have been a mail
  # scanner's
  def end_sessions_for_first_email_sign_in!
    return false unless Account.and(id: id, :ended_sessions_for_email_sign_in.ne => true).update_all('$set' => { ended_sessions_for_email_sign_in: true }).modified_count == 1

    had_sessions = session_token.present?
    end_sessions!
    set(confirm_email_prompt_owed: true) if had_sessions
    had_sessions
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
    set(email_confirmed: true, confirm_email_prompt_owed: false)
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

    absorb_has_many!(victim)
    rebuild_organisation_caches!

    # Reload so dependent: :destroy does not delete associations already transferred
    victim.reload
    victim.destroy

    # Return self for method chaining
    self
  end

  def rebuild_organisation_caches!
    # The collection, not the association: inside an organisationship's after_destroy, the association's loaded copy
    # still holds the row being destroyed
    rels = Organisationship.and(account_id: id)
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

  # Each organisation cache, and the list of organisation ids it should hold, worked out in check_organisation_cache_sync
  ORGANISATION_CACHES = {
    'organisation_ids_cache' => 'all',
    'organisation_ids_public_cache' => 'public',
    'subscribed_organisation_ids_cache' => 'subscribed',
    'unsubscribed_organisation_ids_cache' => 'unsubscribed'
  }.freeze

  # Compares in the database and returns only the accounts out of sync, so nothing else is loaded: one pipeline for
  # accounts with organisationships, another for those whose caches list organisations they have none with
  def self.check_organisation_cache_sync(fix: false)
    sorted = ->(path) { { '$sortArray' => { 'input' => { '$ifNull' => [path, []] }, 'sortBy' => 1 } } }
    mismatched = ->(expected_path, current_path) { { '$ne' => [sorted.(expected_path), sorted.(current_path)] } }

    with_organisationships = Organisationship.collection.aggregate([
      # One per account and organisation, so duplicate rows are counted rather than listed twice
      { '$group' => {
        '_id' => { 'account_id' => '$account_id', 'organisation_id' => '$organisation_id' },
        'rows' => { '$sum' => 1 },
        'public' => { '$max' => { '$ne' => ['$hide_membership', true] } },
        'subscribed' => { '$max' => { '$ne' => ['$unsubscribed', true] } },
        'unsubscribed' => { '$max' => { '$eq' => ['$unsubscribed', true] } }
      } },
      { '$group' => {
        '_id' => '$_id.account_id',
        'all' => { '$push' => '$_id.organisation_id' },
        'public' => { '$push' => { '$cond' => ['$public', '$_id.organisation_id', '$$REMOVE'] } },
        'subscribed' => { '$push' => { '$cond' => ['$subscribed', '$_id.organisation_id', '$$REMOVE'] } },
        'unsubscribed' => { '$push' => { '$cond' => ['$unsubscribed', '$_id.organisation_id', '$$REMOVE'] } },
        'duplicates' => { '$push' => { '$cond' => [{ '$gt' => ['$rows', 1] }, { 'organisation_id' => '$_id.organisation_id', 'count' => '$rows' }, '$$REMOVE'] } }
      } },
      { '$lookup' => { 'from' => 'accounts', 'localField' => '_id', 'foreignField' => '_id', 'as' => 'account',
                       'pipeline' => [{ '$project' => ORGANISATION_CACHES.keys.index_with(1) }] } },
      { '$unwind' => '$account' },
      { '$match' => { '$expr' => { '$or' => [
        *ORGANISATION_CACHES.map { |field, list| mismatched.("$#{list}", "$account.#{field}") },
        { '$gt' => [{ '$size' => '$duplicates' }, 0] }
      ] } } }
    ], allow_disk_use: true).map do |doc|
      { id: doc['_id'], current: doc['account'], expected: doc.slice(*ORGANISATION_CACHES.values), duplicates: doc['duplicates'] }
    end

    without_organisationships = Account.collection.aggregate([
      { '$match' => { '$or' => ORGANISATION_CACHES.keys.map { |field| { "#{field}.0" => { '$exists' => true } } } } },
      { '$project' => ORGANISATION_CACHES.keys.index_with(1) },
      { '$lookup' => { 'from' => 'organisationships', 'localField' => '_id', 'foreignField' => 'account_id', 'as' => 'organisationships',
                       'pipeline' => [{ '$limit' => 1 }, { '$project' => { '_id' => 1 } }] } },
      { '$match' => { 'organisationships' => [] } }
    ]).map { |doc| { id: doc['_id'], current: doc, expected: {}, duplicates: [] } }

    rows = with_organisationships + without_organisationships
    accounts = Account.in(id: rows.pluck(:id)).index_by(&:id)
    ids = ->(list) { Array(list).map(&:to_s).sort }

    out_of_sync = rows.filter_map do |row|
      account = accounts[row[:id]]
      next unless account

      details = ORGANISATION_CACHES.to_h do |field, list|
        [field.to_sym, { current: ids.(row[:current][field]), expected: ids.(row[:expected][list]) }]
      end
      mismatches = details.reject { |_, detail| detail[:current] == detail[:expected] }.keys.map(&:to_s)
      duplicates = row[:duplicates].map { |d| { organisation_id: d['organisation_id'].to_s, count: d['count'] } }.sort_by { |d| d[:organisation_id] }
      if duplicates.any?
        mismatches << 'duplicate_organisationships'
        details[:duplicate_organisationships] = {
          current: duplicates.map { |d| "#{d[:organisation_id]} (#{d[:count]} rows)" },
          expected: duplicates.map { |d| "#{d[:organisation_id]} (1 row)" }
        }
      end

      { account: account, mismatches: mismatches, duplicates: duplicates, details: details }
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
