class AnalyticsProvider
  @all = []

  class << self
    attr_accessor :all
  end

  attr_accessor :name, :cookie_category, :partial, :models, :expire_cookies, :identity_fields

  def initialize(name, options = {})
    @name = name.to_s
    @cookie_category = options[:cookie_category]
    @partial = options[:partial]
    @models = Array(options[:models] || [:organisation])
    @expire_cookies = Array(options[:expire_cookies])
    @identity_fields = Array(options[:identity_fields])
    self.class.all << self
  end

  def self.object(name)
    all.find { |provider| provider.name == name.to_s }
  end

  def self.expire_cookies_for(category)
    all.select { |provider| provider.cookie_category == category }.flat_map(&:expire_cookies).uniq
  end

  def self.facebook_pixel_ids(organisation:, event: nil)
    [organisation&.facebook_pixel_id, event&.facebook_pixel_id]
      .compact
      .map { |id| id.to_s.strip }
      .select { |id| id.match?(/\A\d+\z/) }
      .uniq
  end

  def self.google_ads_conversions(organisation:, event: nil)
    [organisation, event]
      .compact
      .filter_map { |record| record.try(:google_ads_conversion) }
      .uniq { |conversion| [conversion[:id], conversion[:label]] }
  end

  def applies_to?(model)
    model_key = (model.is_a?(Module) ? model.name : model.to_s).underscore.to_sym
    models.include?(model_key)
  end

  def enabled?(organisation:, event: nil)
    [organisation, event].compact.any? do |record|
      next unless applies_to?(record.class)

      identity_fields.any? { |field| record.try(field).present? }
    end
  end
end

AnalyticsProvider.new('plausible',
                      cookie_category: :analytics,
                      partial: 'analytics/plausible_analytics',
                      identity_fields: %i[plausible_analytics_domain])

AnalyticsProvider.new('simple_analytics',
                      cookie_category: :analytics,
                      partial: 'analytics/simple_analytics',
                      identity_fields: %i[simple_analytics_domain])

AnalyticsProvider.new('facebook',
                      cookie_category: :marketing,
                      partial: 'analytics/facebook_pixel',
                      models: %i[organisation event],
                      expire_cookies: %w[_fbp _fbc],
                      identity_fields: %i[facebook_pixel_id])

AnalyticsProvider.new('google_ads',
                      cookie_category: :marketing,
                      partial: 'analytics/google_ads',
                      models: %i[organisation event],
                      expire_cookies: %w[_gcl_aw _gcl_dc _gcl_gb _gcl_au],
                      identity_fields: %i[google_ads_conversion_id])
