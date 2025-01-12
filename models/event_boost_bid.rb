class EventBoostBid
  include Mongoid::Document
  include Mongoid::Timestamps
  include Mongoid::Paranoia

  belongs_to :event

  field :amount, type: Float
  field :currency, type: String
  field :date, type: Date

  validates_presence_of :amount, :currency, :date

  def amount_money
    Money.new amount * 100, currency
  end

  def self.boost
    Event.and(boosted: true).set(boosted: nil)
    EventBoostBid.where(date: Date.today).sort_by(&:amount_money).reverse.first(5).each do |event_boost_bid|
      # event_boost_bid.charge
      event_boost_bid.event.update_attribute(:boosted, true)
    end
  end
end
