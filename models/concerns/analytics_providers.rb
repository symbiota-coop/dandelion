module AnalyticsProviders
  extend ActiveSupport::Concern

  included do
    # Meta/Facebook Pixel
    field :facebook_pixel_id, type: String

    # Google Ads: conversion tag and Enhanced Conversions
    field :google_ads_conversion_id, type: String
    field :google_ads_conversion_label, type: String
    field :google_ads_enhanced_conversions, type: Mongoid::Boolean

    validates_format_of :facebook_pixel_id, with: /\A\d+\z/, allow_nil: true
    validates_format_of :google_ads_conversion_id, with: /\A\d+\z/, allow_nil: true
    validates_format_of :google_ads_conversion_label, with: /\A[A-Za-z0-9_-]+\z/, allow_nil: true
    validates_presence_of :google_ads_conversion_label, if: :google_ads_conversion_id
    validates_presence_of :google_ads_conversion_id, if: :google_ads_conversion_label

    before_validation do
      self.facebook_pixel_id = facebook_pixel_id.strip if facebook_pixel_id
      self.facebook_pixel_id = nil if facebook_pixel_id.blank?

      if google_ads_conversion_id
        self.google_ads_conversion_id = google_ads_conversion_id.strip.sub(/\AAW-/i, '')
        self.google_ads_conversion_id = nil if google_ads_conversion_id.blank?
      end
      if google_ads_conversion_label
        self.google_ads_conversion_label = google_ads_conversion_label.strip
        self.google_ads_conversion_label = nil if google_ads_conversion_label.blank?
      end
    end
  end

  def google_ads_conversion
    return unless google_ads_conversion_id && google_ads_conversion_label

    {
      id: google_ads_conversion_id,
      label: google_ads_conversion_label,
      enhanced: google_ads_enhanced_conversions
    }
  end

  class_methods do
    def analytics_human_attribute_names
      {
        facebook_pixel_id: 'Facebook Pixel ID',
        google_ads_conversion_id: 'Google Ads conversion ID',
        google_ads_conversion_label: 'Google Ads conversion label',
        google_ads_enhanced_conversions: 'Google Ads Enhanced Conversions'
      }
    end

    def analytics_hints
      {
        facebook_pixel_id: 'Your Facebook Pixel ID for tracking sales',
        google_ads_conversion_id: 'From Google Ads tag setup (digits only, or AW-1234567890). Required with the conversion label.',
        google_ads_conversion_label: 'From Google Ads tag setup (not always the same as the conversion name). Required with the conversion ID.',
        google_ads_enhanced_conversions: 'Send hashed email and phone with the purchase so Google can match conversions more accurately'
      }
    end
  end
end
