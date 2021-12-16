class PmailTestship
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :pmail_test
  belongs_to :pmail

  field :account_ids, type: Array
  field :message_ids, type: String
  field :requested_send_at, type: ActiveSupport::TimeWithZone
  field :sent_at, type: ActiveSupport::TimeWithZone

  def self.admin_fields
    {
      summary: { type: :text, edit: false },
      account_ids: { type: :text_area, disabled: true },
      requested_send_at: :datetime,
      sent_at: :datetime,
      pmail_test_id: :lookup,
      pmail_id: :lookup
    }
  end

  validates_uniqueness_of :pmail

  def summary
    "#{pmail_test.name}: #{pmail.subject}"
  end

  def send_pmail
    return if sent_at

    message_ids = pmail.send_batch_message(ab_test: true)
    update_attribute(:sent_at, Time.now)
    update_attribute(:message_ids, message_ids)
  end

  def self.human_attribute_name(attr, options = {})
    {
      pmail_id: 'Email'
    }[attr.to_sym] || super
  end
end
