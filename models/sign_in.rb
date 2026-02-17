class SignIn
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions
  include RequestFields

  belongs_to_without_parent_validation :account

  attr_accessor :skip_increment

  after_create do
    unless skip_increment
      account.set(sign_ins_count: account.sign_ins_count + 1)
      account.set(has_signed_in: true)
    end
  end
end
