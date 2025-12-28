Dandelion::App.helpers do
  def ip_from_cloudflare
    request.env['HTTP_CF_CONNECTING_IP'] || request.env['HTTP_X_FORWARDED_FOR']
  end

  def env_yaml
    request.env.select { |k, v| v.is_a?(String) && k != 'rack.request.form_vars' }.to_yaml
  end

  def current_account
    @current_account ||= Account.find(session[:account_id]) if session[:account_id]
  end

  def event_method_in_organisation_currency(event, method, organisation)
    event.send(method).exchange_to(organisation.currency)
  rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
    0
  end

  def mass_assigning(params, model)
    params ||= {}
    if model.respond_to?(:protected_attributes)
      intersection = model.protected_attributes & params.keys
      raise "Attributes #{intersection} are protected" unless intersection.empty?
    end
    params
  end

  def pagination_details(collection, model: nil)
    page_entries_info(collection, model: model)
  end

  def set_time_zone
    Time.zone = if current_account && current_account.time_zone
                  current_account.time_zone
                elsif session[:time_zone]
                  session[:time_zone]
                elsif File.exist?('GeoLite2-City.mmdb') && ip_from_cloudflare && (max_mind_time_zone = MaxMind::GeoIP2::Reader.new(database: 'GeoLite2-City.mmdb').city(ip_from_cloudflare).location.time_zone)
                  session[:time_zone] = max_mind_time_zone
                else
                  ENV['DEFAULT_TIME_ZONE']
                end
  rescue MaxMind::GeoIP2::AddressNotFoundError
    Time.zone = ENV['DEFAULT_TIME_ZONE']
  rescue StandardError => e
    Honeybadger.notify(e)
    Time.zone = ENV['DEFAULT_TIME_ZONE']
  end
end
