Dandelion::App.helpers do
  def back
    url = request.referer || '/'
    uri = URI.parse(url)
    params = uri.query ? Rack::Utils.parse_query(uri.query) : {}
    params.except!('_')
    params['_'] = Time.now.to_i
    uri.query = Rack::Utils.build_query(params)
    uri.to_s
  end

  def ip_from_cloudflare
    request.env['HTTP_CF_CONNECTING_IP'] || request.env['HTTP_X_FORWARDED_FOR']
  end

  def current_account
    @current_account ||= @current_account_via_api_key || (Account.find(session[:account_id]) if session[:account_id])
  end

  def event_method_in_organisation_currency(event, method, organisation)
    event.send(method).exchange_to(organisation.currency)
  rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
    0
  end

  def mass_assigning(params, model)
    params ||= {}
    if model.respond_to?(:permitted_attributes)
      permitted = model.permitted_attributes.map(&:to_s)
      unpermitted = params.keys.reject { |k| permitted.include?(k.to_s) }
      raise "Attributes #{unpermitted} are not permitted" unless unpermitted.empty?
      params.select { |k, _| permitted.include?(k.to_s) }
    elsif model.respond_to?(:protected_attributes)
      intersection = model.protected_attributes & params.keys.map(&:to_s)
      raise "Attributes #{intersection} are protected" unless intersection.empty?
      params
    else
      params
    end
  end

  def pagination_details(collection, model: nil)
    if collection.total_pages < 2
      case collection.to_a.length
      when 0
        "No #{model.pluralize.downcase} found"
      when 1
        "Displaying <b>1</b> #{model.downcase}"
      else
        "Displaying <b>all #{collection.count}</b> #{model.pluralize.downcase}"
      end
    else
      "Displaying #{model.pluralize.downcase} <b>#{collection.offset + 1} - #{collection.offset + collection.to_a.length}</b> of <b>#{collection.count}</b> in total"
    end
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

  def question_answer_pairs(data)
    return nil unless data[:answers] && data[:questions]

    answers = data[:answers]
    questions = data[:questions]

    answers.map do |i, x|
      question = questions[i]
      answer = if x == 'false'
                 nil
               elsif x.is_a?(Hash)
                 x.values
               else
                 x
               end
      [question, answer]
    end
  end

  def view_base_params
    params.to_h.reject { |k, v| %w[captures format search name display].include?(k) || v == false }
  end

  def view_url(display, path: nil)
    "#{path}?#{view_base_params.merge('search' => 1, 'display' => display).to_query}"
  end

  def theme_css_redundant?(color)
    hex = String(color).strip.downcase.delete_prefix('#')
    hex = "#{hex[0]}#{hex[0]}#{hex[1]}#{hex[1]}#{hex[2]}#{hex[2]}" if hex.length == 3
    hex == '00b963'
  end

  def resolve_feedback_account!
    @account = if admin? && params[:email]
                 Account.find_by(email: params[:email].downcase)
               elsif params[:token]
                 Account.from_feedback_token(@event, params[:token])
               else
                 current_account
               end
    kick! unless @account
    unless @event.attendees.include?(@account)
      flash[:error] = "You didn't attend that event!"
      redirect "/o/#{@event.organisation.slug}/events"
    end
    return unless @event.event_feedbacks.find_by(account: @account)

    flash[:error] = "You've already left feedback on that event"
    redirect "/o/#{@event.organisation.slug}/events"
  end
end
