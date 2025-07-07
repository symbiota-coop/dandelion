class Optionship < DandelionModel
  belongs_to_without_parent_validation :account, index: true
  belongs_to_without_parent_validation :option, index: true
  belongs_to_without_parent_validation :gathering, index: true
  belongs_to_without_parent_validation :membership, index: true

  def self.admin_fields
    {
      account_id: :lookup,
      option_id: :lookup,
      gathering_id: :lookup,
      membership_id: :lookup
    }
  end

  validates_uniqueness_of :account, scope: :option

  before_validation do
    self.membership = gathering.memberships.find_by(account: account) if gathering && account && !membership
    errors.add(:option, 'is full') if option && option.capacity && (option.optionships.count == option.capacity)
  end

  after_save { option.optionships.each { |optionship| optionship.membership.update_requested_contribution } }
  after_destroy { option.optionships.each { |optionship| optionship.membership.try(:update_requested_contribution) } }
end
