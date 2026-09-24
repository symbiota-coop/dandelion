module PublicToken
  extend ActiveSupport::Concern

  included do
    field :token, type: String

    validates_uniqueness_of :token, allow_nil: true

    before_validation do
      # Only mint on create so later saves do not backfill tokens onto legacy
      # records (those stay reachable by Mongo id).
      mint_token if new_record? && token.blank?
    end
  end

  class_methods do
    # Looks up a record by its token. Records that predate tokens (and so were
    # only ever linked to by Mongo id) can still be looked up by id, but records
    # that have a token are deliberately not reachable by their id.
    def find_by_id_or_token(id_or_token)
      return unless id_or_token.is_a?(String) && id_or_token.present?

      if (record = find_by(token: id_or_token))
        record
      elsif id_or_token.match?(/\A[0-9a-fA-F]{24}\z/) && (record = find(id_or_token)) && record.token.blank?
        record
      end
    end
  end

  def mint_token
    loop do
      generated = SecureRandom.uuid
      unless self.class.and(token: generated).exists?
        self.token = generated
        break
      end
    end
  end

  # Records created before tokens were introduced fall back to their Mongo id,
  # which find_by_id_or_token still accepts.
  def public_id
    token.present? ? token : id.to_s
  end
end
