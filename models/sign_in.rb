class SignIn
  include Mongoid::Document
  include Mongoid::Timestamps
  include BelongsToWithoutParentValidation

  belongs_to_without_parent_validation :account, index: true

  field :env, type: String

  def self.admin_fields
    {
      account_id: :lookup,
      env: :text_area
    }
  end

  attr_accessor :skip_increment

  after_create do
    account.update_attribute(:sign_ins_count, account.sign_ins_count + 1) unless skip_increment
  end
end
