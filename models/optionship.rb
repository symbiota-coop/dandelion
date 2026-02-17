class Optionship
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :account
  belongs_to_without_parent_validation :option
  belongs_to_without_parent_validation :gathering
  belongs_to_without_parent_validation :membership

  validates_uniqueness_of :account, scope: :option

  before_validation do
    self.membership = gathering.memberships.find_by(account: account) if gathering && account && !membership
    errors.add(:option, 'is full') if option && option.capacity && (option.optionships.count == option.capacity)
  end

  after_save { option.optionships.each { |optionship| optionship.membership.update_requested_contribution } }
  after_destroy { option.optionships.each { |optionship| optionship.membership.try(:update_requested_contribution) } }
end
