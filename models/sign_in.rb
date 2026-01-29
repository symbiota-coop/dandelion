class SignIn
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions
  include RequestFields

  belongs_to_without_parent_validation :account, index: true

  attr_accessor :skip_increment

  index({ created_at: 1 }, { expire_after_seconds: 1.year.to_i })

  def self.admin_fields
    { account_id: :lookup }.merge(RequestFields.admin_fields)
  end

  after_create do
    unless skip_increment
      account.set(sign_ins_count: account.sign_ins_count + 1)
      account.set(has_signed_in: true)
    end
  end
end
