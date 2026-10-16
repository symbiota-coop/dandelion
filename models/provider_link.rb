class ProviderLink
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :account

  field :provider, type: String
  field :provider_uid, type: String
  field :omniauth_hash, type: Hash
  field :before_email_confirmed, type: Mongoid::Boolean # connected before the account's email was confirmed; see Account#confirm_email!

  validates_presence_of :provider, :provider_uid, :omniauth_hash

  # A link from before before_email_confirmed loads with it nil, which CoreExtensions turns into false in memory, and the
  # account's autosave (accepts_nested_attributes_for) saves loaded links, which would mark it confirmed. Keep it counted
  # as connected before confirmation, as confirm_email! counts nil
  before_save do
    self.before_email_confirmed = true if persisted? && before_email_confirmed_changed? && before_email_confirmed_was.nil?
  end
  validates_uniqueness_of :provider, scope: :account
  validates_uniqueness_of :provider_uid, scope: :provider

  def self.find_for(provider, provider_uid)
    return nil unless provider_uid

    link = find_by(provider: provider, provider_uid: provider_uid)
    return link if link || provider != 'Ethereum'

    # Ethereum uids are now EIP-55 checksummed, but older links stored the address as the wallet reported it (usually lowercase)
    find_by(provider: provider, provider_uid: /\A#{Regexp.escape(provider_uid)}\z/i)
  end
end
