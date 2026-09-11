class Optionship
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :account
  belongs_to_without_parent_validation :option
  belongs_to_without_parent_validation :gathering
  belongs_to_without_parent_validation :membership

  def self.assignable_foreign_keys
    %w[account_id option_id]
  end

  validates_uniqueness_of :account, scope: :option

  before_validation do
    self.gathering = option.gathering if option && !gathering
    self.membership = gathering.memberships.find_by(account: account) if gathering && account && membership&.account_id != account_id
    errors.add(:option, 'is full') if option && option.capacity && (option.optionships.count == option.capacity)
  end

  validates_same_parent :option, via: :gathering

  after_save { option.optionships.each { |optionship| optionship.membership.update_requested_contribution } }
  after_destroy { option.optionships.each { |optionship| optionship.membership.try(:update_requested_contribution) } }
end
