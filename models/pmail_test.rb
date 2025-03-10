class PmailTest
  include Mongoid::Document
  include Mongoid::Timestamps
  class DifferentLists < StandardError; end

  belongs_to :organisation, index: true
  belongs_to :account, index: true

  field :name, type: String
  field :fraction, type: Float
  field :requested_send_at, type: Time
  field :sent_at, type: Time

  def self.admin_fields
    {
      name: :text,
      fraction: :number,
      requested_send_at: :datetime,
      sent_at: :datetime,
      pmail_testships: :collection
    }
  end

  has_many :pmail_testships, dependent: :destroy
  def pmails
    Pmail.and(:id.in => pmail_testships.pluck(:pmail_id))
  end

  validates_presence_of :name, :fraction

  before_validation do
    errors.add(:fraction, 'must be less than 1') if fraction && fraction >= 1
  end

  def winner
    pmails.select(&:sent_at).first
  end

  def assign_account_ids
    pmail_test = self
    raise PmailTest::DifferentLists unless pmails.all? { |pmail| pmail.organisation == pmail_test.organisation } && pmails.map(&:to_selected).uniq.count == 1

    account_ids = pmail_test.pmails.first.to_with_unsubscribes.pluck(:id)
    n = (account_ids.count * pmail_test.fraction).round
    account_ids.shuffle[0..n - 1].in_groups(pmail_test.pmail_testships.count, false).each_with_index do |account_ids, i|
      pmail_test.pmail_testships.order('id asc')[i].update_attribute(:account_ids, account_ids.map(&:to_s))
    end
  end

  def account_ids
    pmail_testships.map(&:account_ids).flatten.compact
  end

  def assign_and_send
    return if sent_at

    assign_account_ids
    pmail_testships(true).each do |pmail_testship|
      unless pmail_testship.requested_send_at
        pmail_testship.update_attribute(:requested_send_at, Time.now)
        pmail_testship.send_pmail
      end
    end
    update_attribute(:sent_at, Time.now)
  end
  handle_asynchronously :assign_and_send
end
