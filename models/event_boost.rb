class EventBoost
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :event
  belongs_to_without_parent_validation :account

  field :start_time, type: Time
  field :end_time, type: Time
  field :hours, type: Integer
  field :hourly_amount, type: Float
  field :currency, type: String
  field :total_amount, type: Float
  field :hourly_weight_gbp_pence, type: Integer
  field :session_id, type: String
  field :payment_intent, type: String
  field :payment_completed, type: Mongoid::Boolean

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
  validate :start_time_on_the_hour
  validate :start_time_in_the_future
  validate :start_time_before_event_listing_ends

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

    active_at(time).and(:event_id.in => event_ids).to_a.each_with_object({}) do |event_boost, weights|
      next unless event_boost.hourly_weight_gbp_pence.to_i.positive?

      weights[event_boost.event_id] = weights.fetch(event_boost.event_id, 0) + event_boost.hourly_weight_gbp_pence
    end
  end

  def self.pick_event_for_scope(events, time: Time.current, rng: Random.new)
    event_ids = events.pluck(:id)
    event_id = weighted_pick(active_hourly_weights_by_event_id(event_ids, time: time), rng: rng)
    return unless event_id

    events.find(event_id)
  end

  def self.weighted_pick(weight_by_event_id, rng: Random.new)
    total_weight = weight_by_event_id.values.sum
    return if total_weight <= 0

    target = rng.rand(total_weight)
    running_total = 0

    weight_by_event_id.each do |event_id, weight|
      next unless weight.positive?

      running_total += weight
      return event_id if target < running_total
    end

    nil
  end

  # Weights for the unfiltered public events listing (same base scope as /events without filters).
  def self.browse_pool_hour_weights(event_id, time: Time.current)
    browse_event_ids = Event.live.publicly_visible.browsable.pluck(:id)
    weights = active_hourly_weights_by_event_id(browse_event_ids, time: time)
    event_w = weights[event_id].to_i
    total = weights.values.sum
    share = total.positive? ? event_w.to_f / total : 0.0
    { event_weight: event_w, total_weight: total, share: share }
  end

  # Sums hourly_amount for each boost (converted to target_currency). Used for UI; lottery still uses GBP pence.
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

  def self.browse_pool_hour_display(event, time: Time.current)
    target_currency = event.currency_or_default
    browse_event_ids = Event.live.publicly_visible.browsable.pluck(:id)
    boosts = active_at(time).and(:event_id.in => browse_event_ids).to_a
    my_boosts = boosts.select { |b| b.event_id == event.id }

    gbp = browse_pool_hour_weights(event.id, time: time)
    {
      event_weight: hourly_spend_sum_in_currency(my_boosts, target_currency),
      pool_total: hourly_spend_sum_in_currency(boosts, target_currency),
      share: gbp[:share],
      currency: target_currency
    }
  end

  def self.convert_hourly_amount_to_gbp_pence(amount, currency)
    return unless amount && currency

    Money.new((amount.to_f * 100).round, currency).exchange_to('GBP').cents
  rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
    nil
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
    self.hourly_weight_gbp_pence = self.class.convert_hourly_amount_to_gbp_pence(hourly_amount, currency)
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

  def start_time_before_event_listing_ends
    return unless start_time && event&.start_time

    errors.add(:start_time, 'must be on or before the event date') unless start_time.to_date <= event.start_time.to_date
  end
end
