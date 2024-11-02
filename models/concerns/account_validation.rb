module AccountValidation
  extend ActiveSupport::Concern

  included do
    validates_presence_of :name, :username, :email
    validates_uniqueness_of   :email,    case_sensitive: false
    validates_presence_of     :password, if: :password_required
    validates_password_strength :password, if: :password_required

    validates_format_of :username, with: /\A[a-z0-9_.]+\z/
    validates_uniqueness_of :username

    before_validation do
      unless username
        u = Bazaar.super_object.parameterize.underscore
        if Account.find_by(username: u)
          n = 1
          n += 1 while Account.find_by(username: "#{u}_#{n}")
          self.username = "#{u}_#{n}"
        else
          self.username = u
        end
      end

      self.api_key = SecureRandom.uuid unless api_key

      self.name = username unless name
      self.name = name.split('@').first if name && name.include?('@')

      self.location = "#{postcode}, #{country}" if postcode && country
      self.sign_in_token = Account.generate_sign_in_token unless sign_in_token
      self.name = name.strip if name
      self.name_transliterated = I18n.transliterate(name) if name
      self.username = username.downcase if username
      self.email = email.downcase.strip if email
      self.sign_ins_count = 0 unless sign_ins_count
      self.number_at_this_location = 0 unless number_at_this_location

      if picture
        begin
          if %w[jpeg png gif pam webp].include?(picture.format)
            picture.name = "#{SecureRandom.uuid}.#{picture.format}"
          else
            self.picture = nil
          end
        rescue StandardError
          self.picture = nil
        end
      end

      if email_changed?
        e = EmailAddress.error(email)
        errors.add(:email, "- #{e}") if e
        self.email_confirmed = nil
      end

      %w[email phone telegram_username].each do |p|
        send("#{p}_privacy=", 'People I follow') unless send("#{p}_privacy")
      end

      errors.add(:bio, 'cannot contain links yet as an anti-spam measure, use Dandelion for a while first!') if !live_player? && (bio =~ %r{https?://})

      errors.add(:name, 'must not contain $') if name && name.include?('$')
      errors.add(:name, 'must not contain @') if name && name.include?('@')
      errors.add(:name, 'must not contain www.') if name && name.include?('www.')
      errors.add(:name, 'must not contain http://') if name && name.include?('http://')
      errors.add(:name, 'must not contain https://') if name && name.include?('https://')
      # errors.add(:name, 'must not contain digits') if self.name and self.name =~ /\d/

      if !password && !crypted_password
        self.password = Account.generate_password # if there's no password, just set one
      end

      errors.add(:date_of_birth, 'is invalid') if age && age <= 0
    end

    after_validation do
      if location_changed?
        if location && ENV['GOOGLE_MAPS_API_KEY']
          geocode || (self.coordinates = nil)
          if coordinates
            self.time_zone = begin
              Timezone.lookup(*coordinates.reverse)
            rescue Timezone::Error::InvalidZone, Timezone::Error::InvalidConfig
              nil
            end
          end
        else
          self.coordinates = nil
        end
      end
    end
  end
end
