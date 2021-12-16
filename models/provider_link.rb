class ProviderLink
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :account, index: true

  field :provider, type: String
  field :provider_uid, type: String
  field :omniauth_hash, type: Hash

  def self.admin_fields
    {
      provider: :text,
      provider_uid: :text,
      omniauth_hash: { type: :text_area, disabled: true },
      account_id: :lookup
    }
  end

  validates_presence_of :provider, :provider_uid, :omniauth_hash
  validates_uniqueness_of :provider, scope: :account_id
  validates_uniqueness_of :provider_uid, scope: :provider
end
