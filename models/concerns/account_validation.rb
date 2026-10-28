module AccountValidation
  extend ActiveSupport::Concern

  included do
    validates_presence_of :name, :username, :email
    validates_uniqueness_of :email
    validates_presence_of :password, if: :password_required
    validates_length_of :password, minimum: 8, if: :password_required

    validates_format_of :username, with: /\A[a-z0-9_.]+\z/
    validates_uniqueness_of :username
    validates_http_url :website

    before_validation do
      self.username = Account.generate_username unless username

      self.api_key = SecureRandom.uuid unless api_key.present?
      self.ics_key = SecureRandom.uuid unless ics_key.present?

      self.name = username unless name
      self.name = name.split('@').first if name && name.include?('@')

      generate_link_token unless link_token

      self.location = "#{postcode}, #{country}" if postcode && country
      self.name = name.strip if name
      self.name_transliterated = I18n.transliterate(name) if name
      self.username = username.downcase if username
      self.email = email.downcase.strip if email
      self.sign_ins_count = 0 unless sign_ins_count
      self.number_at_this_location = 0 unless number_at_this_location

      if email_changed?
        e = EmailAddress.error(email)
        errors.add(:email, "- #{e}") if e
        self.email_confirmed = false
        self.ended_sessions_for_email_sign_in = false # the new address's owner gets their own first sign in (Account#end_sessions_for_first_email_sign_in!)
        self.confirm_email_prompt_owed = false
      end

      %w[email phone location].each do |p|
        send("#{p}_privacy=", 'People I follow') unless send("#{p}_privacy")
      end

      errors.add(:bio, 'cannot contain links yet as an anti-spam measure, use Dandelion for a while first!') if !live_player? && (bio =~ %r{https?://})

      errors.add(:name, 'must not contain $') if name && name.include?('$')
      errors.add(:name, 'must not contain @') if name && name.include?('@')
      errors.add(:name, 'must not contain www.') if name && name.include?('www.')
      errors.add(:name, 'must not contain http://') if name && name.include?('http://')
      errors.add(:name, 'must not contain https://') if name && name.include?('https://')
      # errors.add(:name, 'must not contain digits') if self.name and self.name =~ /\d/

      # If there's no password, just set one. Nobody is given it, so it's hashed at BCrypt's minimum cost
      # (see Account#encrypt_password)
      self.password = @unused_password = Account.generate_password if !password && !crypted_password

      errors.add(:date_of_birth, 'is invalid') if age && age <= 0
    end

    after_validation do
      if location_changed?
        if !location
          self.coordinates = nil
        elsif !skip_geocoding
          look_up_coordinates_and_time_zone
        end
      end
    end
  end

  def look_up_coordinates_and_time_zone
    geocode || (self.coordinates = nil)
    return unless coordinates

    self.time_zone = begin
      Timezone.lookup(*coordinates.reverse)
    rescue Timezone::Error::InvalidZone, Timezone::Error::InvalidConfig, Timezone::Error::Google
      nil
    end
  end

  # For accounts saved with skip_geocoding (checkout), run in the background. Also joins the local groups of
  # organisations the account has joined, which found no coordinates to match when it joined them
  def geocode_location!
    look_up_coordinates_and_time_zone
    set(coordinates: coordinates, time_zone: time_zone)
    organisationships.and(unsubscribed: false).each(&:associate_with_relevant_local_groups!)
  end
end
