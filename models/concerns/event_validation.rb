module EventValidation
  extend ActiveSupport::Concern

  class_methods do
    def slug_candidate
      [*('a'..'z')].sample + [*('0'..'9')].sample + [*('a'..'z'), *('0'..'9')].sample(3).join
    end
  end

  included do
    validates_presence_of :name, :currency
    validates_presence_of :start_time, :end_time, :location, unless: :evergreen?
    validates_uniqueness_of :slug, allow_nil: true
    validates_uniqueness_of :name, scope: [:start_time, :organisation_id], conditions: -> { where(deleted_at: nil) }, message: 'is invalid: an event with this title and start time already exists for this organisation', unless: -> { duplicate || evergreen? }
    validates_uniqueness_of :name, scope: [:organisation_id], conditions: -> { where(deleted_at: nil, evergreen: true) }, message: 'is invalid: an on-demand course with this title already exists for this organisation', if: -> { evergreen? && !duplicate }
    validates_format_of :slug, with: /\A[a-z0-9-]+\z/, if: :slug

    before_validation do
      if evergreen?
        self.start_time = nil
        self.end_time = nil
        self.location = 'Online'
        self.reminder_hours_before = nil
        self.feedback_hours_after = nil
        self.no_tickets_pdf = true
      end

      self.name = name.strip if name
      self.purchase_url = purchase_url.strip if purchase_url
      self.redirect_url = redirect_url.strip.presence if redirect_url
      errors.add(:redirect_url, 'must be a valid http or https URL') if redirect_url && !safe_redirect_url
      self.suggested_donation = suggested_donation.round(2) if suggested_donation
      self.minimum_donation = nil unless suggested_donation
      self.minimum_donation = minimum_donation.round(2) if minimum_donation
      self.organiser = account if account && !revenue_sharer && !organiser && organisation && organisation.stripe_client_id
      self.ai_tagged = false
      self.description = description.gsub('href="www.', 'href="http://www.') if description
      self.suggested_donation = nil if organisation && !organisation.payment_method?
      self.has_organisation = organisation ? true : false
      self.has_recording = extra_info_for_recording_email || recording_email_greeting || recording_email_title ? true : false

      unless slug
        loop do
          self.slug = self.class.slug_candidate
          break unless Event.unscoped.and(slug: slug).exists?
        end
      end

      if new_record? && !duplicate
        org_wide_ok = Organisation.admin_or_event_manager?(organisation, account)
        errors.add(:organisation, "- you don't have permission to create events for this organisation") if !local_group && !activity && !organisation&.allow_event_submissions && !org_wide_ok
        if activity
          activity_ok = Activity.admin?(activity, account) || (organisation && activity.organisation_id == organisation.id && org_wide_ok)
          errors.add(:activity, "- you don't have permission to create events for this activity") unless activity_ok
        end
        if local_group
          local_group_ok = LocalGroup.admin?(local_group, account) || (organisation && local_group.organisation_id == organisation.id && org_wide_ok)
          errors.add(:local_group, "- you don't have permission to create events for this local group") unless local_group_ok
        end
      end

      self.stripe_revenue_adjustment = 0 unless stripe_revenue_adjustment
      self.revenue_share_to_revenue_sharer = 0 unless revenue_share_to_revenue_sharer
      self.revenue_share_to_revenue_sharer = 0 unless revenue_sharer
      self.profit_share_to_organiser = 0 if revenue_sharer
      errors.add(:revenue_share_to_revenue_sharer, 'must be present if a revenue sharer is set') if revenue_sharer && !revenue_share_to_revenue_sharer
      errors.add(:organiser, 'or revenue sharer must be set') if !revenue_sharer && !organiser && organisation && organisation.stripe_client_id

      errors.add(:organisation, 'cannot be changed') if persisted? && organisation_id_changed?
      errors.add(:account, 'cannot be changed') if persisted? && account_id_changed?
      errors.add(:revenue_sharer, 'cannot be changed as the event has orders') if persisted? && revenue_sharer_id_changed? && orders.any?
      errors.add(:revenue_share_to_revenue_sharer, 'cannot be changed as the event has orders') if persisted? && revenue_share_to_revenue_sharer_changed? && orders.any?

      errors.add(:tax_rate_id, 'must start with txr_') if tax_rate_id && !tax_rate_id.starts_with?('txr_')

      if theme_color.present?
        theme_color_normalized = theme_color.start_with?('#') ? theme_color : "##{theme_color}"
        if theme_color_normalized.match?(/\A#[0-9A-Fa-f]{6}\z/)
          self.theme_color = theme_color_normalized
        else
          errors.add(:theme_color, 'must be a valid hex color (e.g. #ABCDEF)')
        end
      end

      errors.add(:revenue_sharer, 'cannot be set if organiser is set') if revenue_sharer && organiser
      errors.add(:revenue_sharer, 'or organiser must be set for this organisation') if organisation && organisation.require_organiser_or_revenue_sharer && !revenue_sharer && !organiser
      errors.add(:revenue_sharer, 'is not connected to this organisation') if revenue_sharer && !revenue_sharer_organisationship
      self.location = 'Online' if location && location.downcase == 'online'
      errors.add(:revenue_share_to_revenue_sharer, 'must be between 1 and 100') if revenue_share_to_revenue_sharer && revenue_share_to_revenue_sharer != 0 && (revenue_share_to_revenue_sharer < 1 || revenue_share_to_revenue_sharer > 100)
      errors.add(:capacity, 'must be greater than 0') if capacity && capacity < 1
      errors.add(:suggested_donation, 'cannot be less than the minimum donation') if suggested_donation && minimum_donation && suggested_donation < minimum_donation
      errors.add(:oc_slug, "cannot be set until the organisation's Open Collective slug is set") if oc_slug && organisation && !organisation.oc_slug
      self.gocardless_instalment_count = nil unless gocardless_instalment_count&.positive?
      errors.add(:gocardless_instalment_count, 'must be between 2 and 24') if gocardless_instalment_count && (gocardless_instalment_count < 2 || gocardless_instalment_count > 24)
      errors.add(:end_time, 'must be after the start time') if end_time && start_time && end_time <= start_time
      errors.add(:feedback_hours_after, 'cannot be negative') if feedback_hours_after&.negative?
      errors.add(:feedback_hours_after, "cannot be more than #{Event::MAX_FEEDBACK_HOURS_AFTER}") if feedback_hours_after && feedback_hours_after > Event::MAX_FEEDBACK_HOURS_AFTER

      # rubocop:disable Style/CombinableLoops
      Event.profit_share_roles.each do |role|
        send("profit_share_to_#{role}=", 0) if send("profit_share_to_#{role}").nil?
      end
      # because the loop below depends on the values first being set in the loop above
      Event.profit_share_roles.each do |role|
        errors.add(:"profit_share_to_#{role}", 'must be between 0% and 100%') if send("profit_share_to_#{role}") < 0 || send("profit_share_to_#{role}") > 100
        errors.add(:"profit_share_to_#{role}", "along with other profit shares must not be greater than #{revenue_share_to_organisation}%") if Event.profit_share_roles.inject(0) { |sum, r| sum + send("profit_share_to_#{r}") } > revenue_share_to_organisation
      end
      # rubocop:enable Style/CombinableLoops

      can_change_org_event_flags = Organisation.admin_or_event_manager?(organisation, last_saved_by)
      {
        featured: false,
        show_emails: false
      }.each do |k, v|
        if !duplicate && !can_change_org_event_flags
          if new_record?
            send("#{k}=", v)
          elsif send("#{k}_changed?")
            errors.add(:"#{k}", '- you cannot change this setting')
          end
        end
      end

      if image
        begin
          self.image_width_unmagic = image.width
          self.image_height_unmagic = image.height
          errors.add(:image, 'must be at least 992px wide') if image_width_unmagic < 800 # legacy images are 800px
          errors.add(:image, 'must be more wide than high') if image_height_unmagic > image_width_unmagic

          errors.add(:image, "must be #{organisation.event_image_required_width}px wide") if organisation && organisation.event_image_required_width && image_width_unmagic != organisation.event_image_required_width
          errors.add(:image, "must be #{organisation.event_image_required_height}px high") if organisation && organisation.event_image_required_height && image_height_unmagic != organisation.event_image_required_height
        rescue StandardError, Dragonfly::Shell::CommandFailed
          errors.add(:image, 'is not supported or corrupted')
        end
      end
    end

    after_validation do
      if location_changed?
        if location
          geocode || (self.coordinates = nil)
          if coordinates
            self.time_zone = begin
              Timezone.lookup(*coordinates.reverse)
            rescue Timezone::Error::InvalidZone, Timezone::Error::InvalidConfig, Timezone::Error::Google
              nil
            end
          end
        else
          self.coordinates = nil
        end
      end
    end

    after_save do
      update_embedding_with_retries if Padrino.env == :production
    end

    handle_asynchronously :update_embedding_with_retries
  end

  def safe_redirect_url
    return unless redirect_url.present?

    uri = begin
      URI.parse(redirect_url)
    rescue URI::InvalidURIError, ArgumentError
      nil
    end
    redirect_url if uri.is_a?(URI::HTTP) && uri.host.present?
  end

  def update_embedding_with_retries
    attempts = 0
    begin
      attempts += 1
      embedding = OpenRouter.embedding(to_public_markdown)
      set(embedding: embedding)
    rescue StandardError => e
      retry if attempts < 3
      ErrorReporting.capture_exception(e)
    end
  end
end
