Dandelion::App.helpers do
  def track_purchase?
    @order && params[:success]
  end

  def purchase_analytics
    @purchase_analytics ||= {
      order_id: @order.id.to_s,
      currency: @order.currency,
      value: @order.value || 0
    }
  end

  def simple_analytics_purchase_params
    purchase_analytics.merge(amount: purchase_analytics[:value]).except(:value)
  end

  def facebook_pixel_ids
    @facebook_pixel_ids ||= AnalyticsProvider.facebook_pixel_ids(organisation: @organisation, event: @event)
  end

  def facebook_pixel_view_content_params
    {
      content_name: @event.name,
      content_ids: [@event.id.to_s],
      content_type: 'product'
    }
  end

  def facebook_pixel_purchase_params
    ticket_type_ids = @order.tickets.map { |t| t.ticket_type_id&.to_s }.compact.uniq
    purchase_analytics.merge(
      content_type: 'product',
      content_ids: ticket_type_ids.present? ? ticket_type_ids : [@order.event_id.to_s],
      content_name: @order.event.try(:name),
      num_items: @order.tickets.count
    ).except(:order_id).compact
  end

  def google_ads_conversions
    @google_ads_conversions ||= AnalyticsProvider.google_ads_conversions(organisation: @organisation, event: @event)
  end

  def google_ads_enhanced_conversions?
    google_ads_conversions.any? { |conversion| conversion[:enhanced] }
  end

  def google_ads_user_data
    account = @order&.account
    return {} unless account

    data = {}
    data[:email] = account.email if account.email
    data[:phone_number] = account.phone if account.phone
    data
  end

  def google_ads_purchase_params
    {
      value: purchase_analytics[:value],
      currency: purchase_analytics[:currency],
      transaction_id: purchase_analytics[:order_id]
    }
  end
end
