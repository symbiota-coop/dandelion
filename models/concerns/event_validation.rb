module EventValidation
  extend ActiveSupport::Concern

  included do
    validates_presence_of :name, :start_time, :end_time, :location, :currency
    validates_uniqueness_of :slug, allow_nil: true
    validates_format_of :slug, with: /\A[a-z0-9-]+\z/, if: :slug

    before_validation do
      self.name = name.strip if name
      self.suggested_donation = suggested_donation.round(2) if suggested_donation
      self.minimum_donation = nil unless suggested_donation
      self.minimum_donation = minimum_donation.round(2) if minimum_donation
      self.organiser = account if account && !revenue_sharer && !organiser && organisation && organisation.stripe_client_id
      self.ai_tagged = nil
      self.description = description.gsub('href="www.', 'href="http://www.') if description

      unless slug
        loop do
          self.slug = ([*('a'..'z')].sample + [*('0'..'9')].sample + [*('a'..'z'), *('0'..'9')].sample(3).join)
          break if Event.find_by(slug: slug).nil?
        end
      end

      if new_record? && !duplicate
        errors.add(:organisation, '- you are not an admin of this organisation') if !local_group && !activity && !Organisation.admin?(organisation, account)
        errors.add(:activity, '- you are not an admin of this activity') if activity && !Activity.admin?(activity, account)
        errors.add(:local_group, '- you are not an admin of this local group') if local_group && !LocalGroup.admin?(local_group, account)
      end

      if zoom_party?
        self.local_group = nil
        self.capacity = nil
      end
      self.stripe_revenue_adjustment = 0 unless stripe_revenue_adjustment
      self.revenue_share_to_revenue_sharer = 0 unless revenue_share_to_revenue_sharer
      self.revenue_share_to_revenue_sharer = 0 unless revenue_sharer
      self.profit_share_to_organiser = 0 if revenue_sharer
      errors.add(:revenue_share_to_revenue_sharer, 'must be present if a revenue sharer is set') if revenue_sharer && !revenue_share_to_revenue_sharer
      errors.add(:organiser, 'or revenue sharer must be set') if !revenue_sharer && !organiser && organisation && organisation.stripe_client_id

      errors.add(:revenue_sharer, 'cannot be changed as the event has orders') if persisted? && revenue_sharer_id_changed? && orders.any?
      errors.add(:revenue_share_to_revenue_sharer, 'cannot be changed as the event has orders') if persisted? && revenue_share_to_revenue_sharer_changed? && orders.any?

      errors.add(:revenue_sharer, 'cannot be set if organiser is set') if revenue_sharer && organiser
      errors.add(:revenue_sharer, 'or organiser must be set for this organisation') if organisation && organisation.require_organiser_or_revenue_sharer && !revenue_sharer && !organiser
      errors.add(:revenue_sharer, 'is not connected to this organisation') if revenue_sharer && !revenue_sharer_organisationship
      self.location = 'Online' if location && location.downcase == 'online'
      errors.add(:revenue_share_to_revenue_sharer, 'must be between 1 and 100') if revenue_share_to_revenue_sharer && revenue_share_to_revenue_sharer != 0 && (revenue_share_to_revenue_sharer < 1 || revenue_share_to_revenue_sharer > 100)
      errors.add(:affiliate_credit_percentage, 'must be between 1 and 100') if affiliate_credit_percentage && (affiliate_credit_percentage < 1 || affiliate_credit_percentage > 100)
      errors.add(:capacity, 'must be greater than 0') if capacity && capacity.zero?
      errors.add(:suggested_donation, 'cannot be less than the minimum donation') if suggested_donation && minimum_donation && suggested_donation < minimum_donation
      errors.add(:oc_slug, "cannot be set until the organisation's Open Collective slug is set") if oc_slug && organisation && !organisation.oc_slug
      errors.add(:end_time, 'must be after the start time') if end_time && start_time && end_time <= start_time

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

      {
        zoom_party: false,
        monthly_donors_only: false,
        no_discounts: false,
        include_in_parent: false,
        affiliate_credit_percentage: organisation.try(:affiliate_credit_percentage),
        featured: false,
        show_emails: false,
        refund_deleted_orders: true
      }.each do |k, v|
        if !duplicate && !Organisation.admin?(organisation, last_saved_by)
          if new_record?
            send("#{k}=", v)
          elsif send("#{k}_changed?")
            errors.add(:"#{k}", '- you cannot change this setting')
          end
        end
      end

      if image
        begin
          self.image = image.encode('jpg') if image && !%w[jpg jpeg].include?(image.format)
        rescue StandardError
          self.image = nil
        end

        errors.add(:image, 'must be at least 992px wide') if image && image.width < 800 # legacy images are 800px
        errors.add(:image, 'must be more wide than high') if image && image.height > image.width

        errors.add(:image, "must be #{organisation.event_image_required_width}px wide") if organisation && organisation.event_image_required_width && !(image && image.width == organisation.event_image_required_width)
        errors.add(:image, "must be #{organisation.event_image_required_height}px high") if organisation && organisation.event_image_required_height && !(image && image.height == organisation.event_image_required_height)

      end
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
