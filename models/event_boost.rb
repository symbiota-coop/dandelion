class EventBoost
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  MINIMUM_HOURLY_AMOUNT_MULTIPLIER = 1

  belongs_to_without_parent_validation :event
  belongs_to_without_parent_validation :account

  field :start_time, type: Time
  field :end_time, type: Time
  field :hours, type: Integer
  field :currency, type: String
  field :hourly_amount, type: Float
  field :total_amount, type: Float
  field :hourly_weight_gbp_pence, type: Integer
  field :session_id, type: String
  field :payment_intent, type: String
  field :payment_completed, type: Boolean

  validates_presence_of :event, :account, :start_time, :hours, :hourly_amount, :currency, :total_amount
  validates_inclusion_of :currency, in: FIAT_CURRENCIES
  validates_numericality_of :hours, only_integer: true, greater_than: 0
  validates_numericality_of :hourly_amount, greater_than: 0
  validates_numericality_of :hourly_weight_gbp_pence, only_integer: true, greater_than: 0
  validates_uniqueness_of :session_id, :payment_intent, allow_nil: true

  def self.permitted_attributes
    %w[start_time hours hourly_amount currency]
  end

  validate :event_can_be_boosted
  validate :hourly_amount_meets_minimum
  validate :start_time_on_the_hour
  validate :start_time_in_the_future

  before_validation :set_derived_fields

  def self.complete
    self.and(payment_completed: true)
  end

  def self.incomplete
    self.and(payment_completed: false)
  end

  def self.active_at(time = Time.current)
    complete.and(:start_time.lte => time, :end_time.gt => time)
  end

  def self.active_hourly_weights_by_event_id(event_ids, time: Time.current)
    return {} if event_ids.blank?

    active_at(time).and(:event_id.in => event_ids).only(:event_id, :hourly_weight_gbp_pence).to_a.each_with_object({}) do |event_boost, weights|
      next unless event_boost.hourly_weight_gbp_pence.to_i.positive?

      weights[event_boost.event_id] = weights.fetch(event_boost.event_id, 0) + event_boost.hourly_weight_gbp_pence
    end
  end

  def self.pick_event_for_scope(events, time: Time.current, rng: Random.new)
    boost_event_ids = active_at(time).distinct(:event_id).compact
    return if boost_event_ids.blank?

    event_ids = events.and(:id.in => boost_event_ids).pluck(:id)
    return if event_ids.blank?

    weight_by_event_id = active_hourly_weights_by_event_id(event_ids, time: time)
    total_weight = weight_by_event_id.values.sum
    return if total_weight <= 0

    target = rng.rand(total_weight)
    running_total = 0
    picked_event_id = nil

    weight_by_event_id.each do |event_id, weight|
      next unless weight.positive?

      running_total += weight
      if target < running_total
        picked_event_id = event_id
        break
      end
    end
    return unless picked_event_id

    events.find(picked_event_id)
  end

  def self.hourly_spend_sum_in_currency(boosts, target_currency)
    return Money.new(0, target_currency) if boosts.blank?

    boosts.reduce(Money.new(0, target_currency)) do |sum, eb|
      next sum unless eb.hourly_amount.to_f.positive?

      chunk = Money.new((eb.hourly_amount.to_f * 100).round, eb.currency).exchange_to(target_currency)
      sum + chunk
    rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
      sum
    end
  end

  def self.pool_hour_stats(event, slot_start:)
    time = slot_start + 30.minutes
    slot_end = slot_start + 1.hour
    impression_count = event.event_boost_impressions.and(
      :created_at.gte => slot_start,
      :created_at.lt => slot_end
    ).count

    target_currency = event.currency_or_default
    browse_event_ids = Event.live.publicly_visible.browsable.future(time.to_date).pluck(:id)

    weights = active_hourly_weights_by_event_id(browse_event_ids, time: time)
    boosts = active_at(time).and(:event_id.in => browse_event_ids).only(:hourly_amount, :currency, :event_id).to_a
    my_boosts = boosts.select { |b| b.event_id == event.id }
    event_w = weights[event.id].to_i
    total_w = weights.values.sum
    share = total_w.positive? ? event_w.to_f / total_w : 0.0

    {
      event_weight: hourly_spend_sum_in_currency(my_boosts, target_currency),
      pool_total: hourly_spend_sum_in_currency(boosts, target_currency),
      share: share,
      currency: target_currency,
      slot_start: slot_start,
      impression_count: impression_count
    }
  end

  def self.minimum_hourly_amount(currency)
    m = FiatCurrency.minimum_unit_amount(currency)
    return nil unless m

    m * MINIMUM_HOURLY_AMOUNT_MULTIPLIER
  end

  def complete?
    payment_completed?
  end

  def incomplete?
    !payment_completed?
  end

  def active?(time = Time.current)
    complete? && start_time && end_time && start_time <= time && end_time > time
  end

  def status(time = Time.current)
    return { 'Pending payment' => 'label-default' } unless complete?
    return { 'Active now' => 'label-primary' } if active?(time)
    return { 'Upcoming' => 'label-primary' } if start_time && start_time > time

    { 'Ended' => 'label-default' }
  end

  private

  def set_derived_fields
    return unless start_time && hours && hourly_amount && currency

    self.end_time = start_time + hours.hours
    self.total_amount = (hourly_amount.to_f * hours.to_i).round(2)
    self.hourly_weight_gbp_pence = begin
      Money.new((hourly_amount.to_f * 100).round, currency).exchange_to('GBP').cents
    rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
      nil
    end
  end

  def hourly_amount_meets_minimum
    return unless hourly_amount && currency

    min = self.class.minimum_hourly_amount(currency)
    return unless min && hourly_amount < min

    formatted = Money.new((min * 100).round, currency).format(no_cents_if_whole: true)
    errors.add(:hourly_amount, "must be at least #{formatted}")
  end

  def event_can_be_boosted
    return unless event

    errors.add(:event, 'must be live') unless event.live?
    errors.add(:event, 'must be publicly visible') unless event.publicly_visible?
    errors.add(:event, 'must be browsable') unless event.browsable?
  end

  def start_time_on_the_hour
    return unless start_time

    errors.add(:start_time, 'must be on the hour') unless start_time.min.zero? && start_time.sec.zero?
  end

  def start_time_in_the_future
    return unless start_time

    errors.add(:start_time, 'must be this hour or later') unless start_time >= Time.current.beginning_of_hour
  end
end
