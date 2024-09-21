module OrganisationValidation
  extend ActiveSupport::Concern

  included do
    validates_presence_of :name, :slug, :currency
    validates_uniqueness_of :slug
    validates_format_of :slug, with: /\A[a-z0-9-]+\z/
    validates_format_of :stripe_sk, with: /\A[a-z0-9_]+\z/i, allow_nil: true
    validates_format_of :stripe_pk, with: /\A[a-z0-9_]+\z/i, allow_nil: true

    before_validation do
      self.currency = 'GBP' unless currency
      self.ticket_email_greeting = ticket_email_greeting_default unless ticket_email_greeting
      self.recording_email_greeting = recording_email_greeting_default unless recording_email_greeting
      self.feedback_email_body = feedback_email_body_default unless feedback_email_body
      errors.add(:affiliate_credit_percentage, 'must be between 1 and 100') if affiliate_credit_percentage && (affiliate_credit_percentage < 1 || affiliate_credit_percentage > 100)

      errors.add(:mailgun_domain, 'must not be a sandbox domain') if mailgun_domain && mailgun_domain.starts_with?('sandbox') && mailgun_domain.ends_with?('mailgun.org')

      errors.add(:mailgun_domain, 'must be provided if other Mailgun details have been provided') if (mailgun_api_key || mailgun_region) && !mailgun_domain
      errors.add(:mailgun_api_key, 'must be provided if other Mailgun details have been provided') if (mailgun_domain || mailgun_region) && !mailgun_api_key
      errors.add(:mailgun_region, 'must be provided if other Mailgun details have been provided') if (mailgun_domain || mailgun_api_key) && !mailgun_region

      errors.add(:event_image_required_width, 'must be greater than 0') if event_image_required_width && event_image_required_width <= 0
      errors.add(:event_image_required_height, 'must be greater than 0') if event_image_required_height && event_image_required_height <= 0

      if image
        begin
          if %w[jpeg png gif pam].include?(image.format)
            image.name = "#{SecureRandom.uuid}.#{image.format}"
          else
            errors.add(:image, 'must be an image')
          end
        rescue StandardError
          self.image = nil
          errors.add(:image, 'must be an image')
        end
      end

      if Padrino.env == :production && account && !account.admin?
        errors.add(:stripe_sk, 'must start with sk_live_') if stripe_sk && !stripe_sk.starts_with?('sk_live_')
        errors.add(:stripe_pk, 'must start with pk_live_') if stripe_pk && !stripe_pk.starts_with?('pk_live_')
      end
      errors.add(:stripe_sk, 'must be present if Stripe public key is present') if stripe_pk && !stripe_sk
    end

    after_validation do
      if location_changed?
        if location && ENV['GOOGLE_MAPS_API_KEY']
          geocode || (self.coordinates = nil)
        else
          self.coordinates = nil
        end
      end
    end
  end
end
