class EventBoostBid
  include Mongoid::Document
  include Mongoid::Timestamps
  include BelongsToWithoutParentValidation

  include Mongoid::Paranoia

  belongs_to_without_parent_validation :event, index: true

  field :amount, type: Float
  field :currency, type: String
  field :date, type: Date

  validates_presence_of :amount, :currency, :date

  def amount_money
    Money.new amount * 100, currency
  end

  def self.boost
    # Reset all boosted events
    Event.and(boosted: true).set(boosted: nil)

    # Get today's bids sorted by amount (highest first)
    bids_today = EventBoostBid.and(date: Date.today).sort_by(&:amount_money).reverse

    # "We auction off 5 boosts each day. The price of a boost is the price of the 5th highest bid
    # - so winners tend to pay less than what they bid."

    # Take top 5 bids (or all if less than 5)
    winning_bids = bids_today.first(5)
    return if winning_bids.empty?

    # Use the last winning bid as the second price
    # second_price = winning_bids.last.amount_money

    winning_bids.each do |event_boost_bid|
      # Charge second price
      # event_boost_bid.charge(second_price.amount)
      event_boost_bid.event.set(boosted: true)
    end
  end
end
