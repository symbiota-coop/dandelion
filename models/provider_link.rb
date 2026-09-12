class ProviderLink
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :account

  field :provider, type: String
  field :provider_uid, type: String
  field :omniauth_hash, type: Hash


  validates_presence_of :provider, :provider_uid, :omniauth_hash
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
