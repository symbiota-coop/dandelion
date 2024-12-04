class Gathering
  include Mongoid::Document
  include Mongoid::Timestamps
  extend Dragonfly::Model

  include GatheringFields
  include GatheringAssociations
  include Geocoded
  include EvmTransactions
  include StripeWebhooks

  def self.fs(slug)
    find_by(slug: slug)
  end

  def self.spring_clean
    ignore = %i[memberships teams teamships notifications_as_notifiable notifications_as_circle]
    Gathering.and(listed: true).each do |gathering|
      next unless Gathering.reflect_on_all_associations(:has_many).all? do |assoc|
        gathering.send(assoc.name).count == 0 || ignore.include?(assoc.name)
      end

      if gathering.created_at < 1.month.ago && gathering.memberships.count == 1
        puts gathering.slug
        # gathering.destroy
      end
    end
  end

  def self.admin?(gathering, account)
    account && gathering and ((membership = gathering.memberships.find_by(account: account)) and membership.admin?)
  end

  def self.currencies
    CURRENCY_OPTIONS
  end

  validates_presence_of :name, :slug, :currency
  validates_uniqueness_of :slug
  validates_format_of :slug, with: /\A[a-z0-9-]+\z/

  before_validation do
    errors.add(:fixed_threshold, 'cannot be negative') if fixed_threshold && fixed_threshold.negative?
    errors.add(:member_limit, 'must be positive') if fixed_threshold && !fixed_threshold.positive?

    errors.add(:stripe_sk, 'must start with sk_') if stripe_sk && !stripe_sk.starts_with?('sk_')
    errors.add(:stripe_pk, 'must start with pk_') if stripe_pk && !stripe_pk.starts_with?('pk_')
    errors.add(:stripe_sk, 'must be present if Stripe public key is present') if stripe_pk && !stripe_sk

    if image
      begin
        if %w[jpeg png gif pam webp].include?(image.format)
          image.name = "#{SecureRandom.uuid}.#{image.format}"
        else
          errors.add(:image, 'must be an image')
        end
      rescue StandardError
        self.image = nil
        errors.add(:image, 'must be an image')
      end
    end

    self.listed = nil if privacy == 'secret'
    self.balance = 0 if balance.nil?
    self.invitations_granted = 0 if invitations_granted.nil?
    self.processed_via_dandelion = 0 if processed_via_dandelion.nil?
    self.enable_teams = true if enable_budget
    self.member_limit = memberships.count if member_limit && (member_limit < memberships.count)
    self.fixed_threshold = nil if democratic_threshold
    true
  end

  after_validation do
    if location_changed?
      if location && ENV['GOOGLE_MAPS_API_KEY']
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
      general.teamships.create! account: account, prevent_notifications: true
    end
  end

  def circle
    self
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
      i += if option.split_cost && option.optionships.count > 0
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
      Payment.create(payment_attempt: @payment_attempt) if (@payment_attempt = payment_attempts.find_by(currency: token, evm_amount: amount))
    end
  end

  def radio_scopes
    []

    #    if ask_for_date_of_birth
    #      youngest = Account.and(:id.in => memberships.pluck(:account_id)).and(:date_of_birth.ne => nil).order('date_of_birth desc').first
    #      oldest = Account.and(:id.in => memberships.pluck(:account_id)).and(:date_of_birth.ne => nil).order('date_of_birth asc').first
    #      if youngest and oldest
    #        x << [:p, 'all', 'All ages', memberships]
    #        (youngest.age.to_s[0].to_i).upto(oldest.age.to_s[0].to_i) do |p| p = "#{p}0".to_i;
    #          x << [:p, p, "People in their #{p}s", memberships.and(:account_id.in => Account.and(:date_of_birth.lte => (Date.current-p.years)).and(:date_of_birth.gt => (Date.current-(p+10).years)).pluck(:id))]
    #        end
    #      end
    #    end
  end

  def check_box_scopes
    y = []

    y << [:admin, 'Admins', memberships.and(admin: true)]

    y << [:women, 'Women', memberships.and(:account_id.in => members.and(:gender.in => ['Woman', 'Cis Woman']).pluck(:id))]
    y << [:men, 'Men', memberships.and(:account_id.in => members.and(:gender.in => ['Man', 'Cis Man']).pluck(:id))]
    y << [:other_genders, 'Other genders', memberships.and(:account_id.in => members.and(:gender.nin => ['Woman', 'Cis Woman', 'Man', 'Cis Man', nil]).pluck(:id))]
    y << [:unknown_gender, 'Gender not listed', memberships.and(:account_id.in => members.and(gender: nil).pluck(:id))]

    y << [:paid_something, 'Paid something', memberships.and(:paid.gt => 0)]
    y << [:paid_nothing, 'Paid nothing', memberships.and(paid: 0)]
    y << [:more_to_pay, 'More to pay', memberships.and(:id.in => memberships.where('this.paid < this.requested_contribution').pluck(:id))]
    y << [:no_more_to_pay, 'No more to pay', memberships.and(:id.in => memberships.where('this.paid == this.requested_contribution').pluck(:id))]
    y << [:overpaid, 'Overpaid', memberships.and(:id.in => memberships.where('this.paid > this.requested_contribution').pluck(:id))]

    y << [:invitations_granted, 'Custom number of invitations', memberships.and(:invitations_granted.ne => nil)]

    if enable_rotas
      y << [:with_shifts, 'With shifts', memberships.and(:account_id.in => shifts.pluck(:account_id))]
      y << [:without_shifts, 'Without shifts', memberships.and(:account_id.nin => shifts.pluck(:account_id))]
      if enable_shift_worth
        y << [:sufficient_points, 'Sufficient shift points', memberships.and(:id.in => memberships.select { |m| m.shift_points >= (m.shift_points_required || 0) }.pluck(:id))]
        y << [:insufficient_points, 'Insufficient shift points', memberships.and(:id.in => memberships.select { |m| m.shift_points < (m.shift_points_required || 0) }.pluck(:id))]
      end
    end

    if enable_teams
      y << [:with_teams, 'With teams', memberships.and(:account_id.in => teamships.and(:team_id.nin => teams.and(name: 'General').pluck(:id)).pluck(:account_id))]
      y << [:without_teams, 'Without teams', memberships.and(:account_id.nin => teamships.and(:team_id.nin => teams.and(name: 'General').pluck(:id)).pluck(:account_id))]
    end

    if enable_contributions
      %w[Tier Accommodation Transport Food Extra].each do |o|
        if optionships.and(:option_id.in => options.and(type: o).pluck(:id)).count > 0
          y << [:"with_#{o.downcase}", "With #{o.downcase}", memberships.and(:account_id.in => optionships.and(:option_id.in => options.and(type: o).pluck(:id)).pluck(:account_id))]
          y << [:"without_#{o.downcase}", "Without #{o.downcase}", memberships.and(:account_id.nin => optionships.and(:option_id.in => options.and(type: o).pluck(:id)).pluck(:account_id))]
        end
      end
    end

    y << [:threshold, 'Suggesting magic number', memberships.and(:desired_threshold.ne => nil)] if democratic_threshold

    y
  end
end
