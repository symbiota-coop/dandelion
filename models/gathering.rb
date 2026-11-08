class Gathering
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions
  include SlugLookup

  extend Dragonfly::Model
  include GatheringFields
  include GatheringAssociations
  include Geocoded
  include EvmTransactions
  include StripeWebhooks
  include ImageWithValidation
  include Searchable

  def self.fs(slug)
    find_by(slug: slug)
  end

  def self.prewarmed_image_derivative_sizes
    %w[400x400]
  end

  def self.prewarm_opengraph_image_derivative?
    true
  end

  def self.search_fields
    %w[name slug intro_for_non_members]
  end

  # Its Atlas Search index maps name and slug as autocomplete too, so searches match the start of a word in them (Searchable)
  def self.autocomplete_fields
    %w[name slug]
  end

  def self.search_scope
    self.and(listed: true).and(:privacy.ne => 'secret')
  end

  def self.secret_fields
    %w[stripe_sk]
  end

  def self.protected_attributes
    %w[
      redirect_home balance processed_via_dandelion membership_count
      stripe_endpoint_secret paypal_email choose_and_pay_label
      coordinates has_image
    ]
  end

  def self.spring_clean
    ignore = %i[memberships teams teamships notifications_as_notifiable notifications_as_circle]
    Gathering.and(listed: true).each do |gathering|
      next unless Gathering.reflect_on_all_associations(:has_many).all? do |assoc|
        gathering.send(assoc.name).empty? || ignore.include?(assoc.name)
      end

      if gathering.created_at < 1.month.ago && gathering.memberships.count == 1
        puts gathering.slug
        # gathering.destroy
      end
    end
  end

  def self.admin?(gathering, account)
    account && gathering and (account.admin? || ((membership = gathering.memberships.find_by(account: account)) and membership.admin?))
  end

  def self.currencies
    CURRENCY_OPTIONS
  end

  validates_presence_of :name, :slug, :currency
  validates_uniqueness_of :slug
  validates_format_of :slug, with: /\A[a-z0-9-]+\z/

  before_validation do
    errors.add(:fixed_threshold, 'cannot be negative') if fixed_threshold && fixed_threshold.negative?
    errors.add(:member_limit, 'must be positive') if member_limit && !member_limit.positive?

    errors.add(:stripe_sk, 'must start with sk_') if stripe_sk && !stripe_sk.starts_with?('sk_')
    errors.add(:stripe_pk, 'must start with pk_') if stripe_pk && !stripe_pk.starts_with?('pk_')
    errors.add(:stripe_sk, 'must be present if Stripe public key is present') if stripe_pk && !stripe_sk

    self.currency = currency_was if persisted? && currency_changed?

    self.listed = false if privacy == 'secret'
    self.welcome_email = welcome_email_default if welcome_email.nil?
    self.balance = 0 if balance.nil?
    self.invitations_granted = 0 if invitations_granted.nil?
    self.processed_via_dandelion = 0 if processed_via_dandelion.nil?
    self.enable_teams = true if enable_budget
    self.member_limit = memberships.count if member_limit && (member_limit < memberships.count)
    self.fixed_threshold = nil if democratic_threshold

    if measure_image?
      begin
        self.image_width_unmagic = image.width
        self.image_height_unmagic = image.height
      rescue StandardError, Dragonfly::Shell::CommandFailed
        errors.add(:image, 'is not supported or corrupted')
      end
    end

    true
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
    notifications_as_notifiable.create! circle: circle, type: 'created_gathering'
    memberships.create! account: account, admin: true
    if (dandelion = Organisation.find_by(slug: 'dandelion'))
      dandelion.organisationships.create account: account
    end
    if enable_teams
      general = teams.create! name: 'General', account: account, prevent_notifications: true
      general.teamships.create! account: account, gathering: self, prevent_notifications: true
    end
  end

  def stripe_webhook_url
    "#{ENV['BASE_URI']}/g/#{slug}/stripe_webhook"
  end

  def circle
    self
  end

  # Whether the members table shows tickets and shifts, worked out once for the table rather than once a row
  def any_events?
    @any_events = events.exists? unless defined?(@any_events)
    @any_events
  end

  def rotas_shown?
    @rotas_shown = enable_rotas? && rotas.exists? unless defined?(@rotas_shown)
    @rotas_shown
  end

  def welcome_email_default
    %(<p>Hi %recipient.firstname%,</p>

<p>You're now a member of [gathering_name] on Dandelion.</p>

<p>
  [sign_in_details]
</p>)
  end

  # Filled in after rich_text: sign_in_details is Dandelion's own %recipient.token% link. It goes first so a name
  # can't add one
  def welcome_email_html(sign_in_details)
    EmailHelper.html(content: welcome_email || welcome_email_default) do |content|
      EmailHelper.rich_text(content)
                 .gsub('[sign_in_details]', sign_in_details)
                 .gsub('[gathering_name]', EmailHelper.h(name))
    end
  end

  def application_questions_a
    q = (application_questions || '').split("\n").map(&:strip).reject(&:blank?)
    q.empty? ? [] : q
  end

  def joining_questions_a
    q = (joining_questions || '').split("\n").map(&:strip).reject(&:blank?)
    q.empty? ? [] : q
  end

  def vouchers
    if enable_supporters
      'proposers + supporters (with at least one proposer)'
    else
      (threshold == 1 ? 'proposer' : 'proposers')
    end
  end

  def incomings
    i = 0
    options.each do |option|
      i += if option.split_cost && option.optionships.exists?
             option.cost
           else
             option.cost * option.optionships.count
           end
    end
    i
  end

  def anonymise_proposers
    false
  end

  def enable_proposers
    true
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

  def threshold
    democratic_threshold ? median_threshold : fixed_threshold
  end

  def median_threshold
    array = memberships.pluck(:desired_threshold).compact
    return if array.empty?

    sorted = array.sort
    len = sorted.length
    ((sorted[(len - 1) / 2] + sorted[len / 2]) / 2.0).round
  end

  def clear_up_optionships!
    memberships.each do |membership|
      membership.optionships.each do |optionship|
        optionship.destroy if optionship.created_at < 1.hour.ago && optionship.option.cost > membership.paid
      end
    end
  end

  def check_evm_account
    evm_transactions.each do |token, amount|
      if (payment = payments.find_by(currency: token, evm_amount: amount)) && !payment.payment_completed
        payment.payment_completed!
      end
    end
  end

  def copy_structure_to(destination, account:)
    timetables.each do |timetable|
      new_timetable = destination.timetables.create!(name: timetable.name, account: account)
      timetable.tslots.each do |tslot|
        new_timetable.tslots.create!(name: tslot.name, o: tslot.o)
      end
      timetable.spaces.each do |space|
        new_timetable.spaces.create!(name: space.name, o: space.o)
      end
    end

    rotas.each do |rota|
      new_rota = destination.rotas.create!(name: rota.name, account: account)
      rota.rslots.each do |rslot|
        new_rota.rslots.create!(name: rslot.name, o: rslot.o, worth: rslot.worth)
      end
      rota.roles.each do |role|
        new_rota.roles.create!(name: role.name, o: role.o, worth: role.worth)
      end
    end

    options.each do |option|
      destination.options.create!(
        account: option.account,
        name: option.name,
        description: option.description,
        capacity: option.capacity,
        cost: option.cost,
        split_cost: option.split_cost,
        type: option.type,
        by_invitation: option.by_invitation,
        hide_members: option.hide_members
      )
    end
  end

  # The filters above the members list: a select per question whose answers rule each other out (gender, shifts...),
  # each answer a [param value, label, memberships] triple, and a checkbox for each filter on its own. Filters combine
  # with AND
  def member_filters
    selects = []
    checkboxes = []

    selects << [:gender, 'Gender', [
      [:women, 'Women', memberships.and(:account_id.in => members.and(:gender.in => ['Woman', 'Cis Woman']).pluck(:id))],
      [:men, 'Men', memberships.and(:account_id.in => members.and(:gender.in => ['Man', 'Cis Man']).pluck(:id))],
      [:other_genders, 'Other genders', memberships.and(:account_id.in => members.and(:gender.nin => ['Woman', 'Cis Woman', 'Man', 'Cis Man', nil]).pluck(:id))],
      [:unknown_gender, 'Gender not listed', memberships.and(:account_id.in => members.and(gender: nil).pluck(:id))]
    ]]

    selects << [:paid, 'Paid', [
      [:paid_something, 'Paid something', memberships.and(:paid.gt => 0)],
      [:paid_nothing, 'Paid nothing', memberships.and(paid: 0)]
    ]]
    selects << [:balance, 'Balance', [
      [:more_to_pay, 'More to pay', memberships.and('$expr' => { '$lt' => ['$paid', '$requested_contribution'] })],
      [:no_more_to_pay, 'No more to pay', memberships.and('$expr' => { '$eq' => ['$paid', '$requested_contribution'] })],
      [:overpaid, 'Overpaid', memberships.and('$expr' => { '$gt' => ['$paid', '$requested_contribution'] })]
    ]]

    if enable_rotas
      shift_account_ids = shifts.pluck(:account_id)
      selects << [:shifts, 'Shifts', [
        [:with_shifts, 'With shifts', memberships.and(:account_id.in => shift_account_ids)],
        [:without_shifts, 'Without shifts', memberships.and(:account_id.nin => shift_account_ids)]
      ]]
      if enable_shift_worth
        selects << [:shift_points, 'Shift points', [
          [:sufficient_points, 'Sufficient shift points', memberships.and(:id.in => memberships.select { |m| m.shift_points >= (m.shift_points_required || 0) }.pluck(:id))],
          [:insufficient_points, 'Insufficient shift points', memberships.and(:id.in => memberships.select { |m| m.shift_points < (m.shift_points_required || 0) }.pluck(:id))]
        ]]
      end
    end

    if enable_teams
      team_account_ids = teamships.and(:team_id.nin => teams.and(name: 'General').pluck(:id)).pluck(:account_id)
      selects << [:teams, 'Teams', [
        [:with_teams, 'With teams', memberships.and(:account_id.in => team_account_ids)],
        [:without_teams, 'Without teams', memberships.and(:account_id.nin => team_account_ids)]
      ]]
    end

    if enable_contributions
      %w[Tier Accommodation Transport Food Extra].each do |o|
        option_account_ids = optionships.and(:option_id.in => options.and(type: o).pluck(:id)).pluck(:account_id)
        next if option_account_ids.empty?

        selects << [:"#{o.downcase}", o, [
          [:"with_#{o.downcase}", "With #{o.downcase}", memberships.and(:account_id.in => option_account_ids)],
          [:"without_#{o.downcase}", "Without #{o.downcase}", memberships.and(:account_id.nin => option_account_ids)]
        ]]
      end
    end

    checkboxes << [:admin, 'Admins', memberships.and(admin: true)]
    checkboxes << [:threshold, 'Suggesting magic number', memberships.and(:desired_threshold.ne => nil)] if democratic_threshold

    { selects: selects, checkboxes: checkboxes }
  end
end
