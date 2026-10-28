Dandelion::App.helpers do
  # Answers the block's repeated queries from memory (the driver's query cache), for a list whose items mostly load
  # the same few records, like a newsfeed's. The driver keeps what it cached until it's cleared, so it's cleared
  # afterwards, or later requests on the same thread would read stale results
  def with_query_cache(&)
    Mongo::QueryCache.cache(&)
  ensure
    Mongo::QueryCache.clear
  end

  def back(fragment = nil)
    uri = internal_redirect_uri(request.referer) || URI.parse('/')
    params = uri.query ? Rack::Utils.parse_query(uri.query) : {}
    params.except!('_')
    params['_'] = Time.now.to_i
    uri.query = Rack::Utils.build_query(params)
    uri.fragment = fragment.to_s.delete_prefix('#') if fragment
    uri.to_s
  end

  def internal_redirect_uri(url)
    return unless url.present?

    uri = URI.parse(url)
    uri.user = nil
    uri.password = nil
    if uri.host
      return unless %w[http https].include?(uri.scheme)
      return unless allowed_redirect_hosts.any? { |host| uri.host.casecmp?(host) }
    else
      return if uri.scheme
      return unless uri.path&.start_with?('/')
    end
    uri
  rescue URI::InvalidURIError
    nil
  end

  def allowed_redirect_hosts
    hosts = [request.host]
    hosts << URI.parse(ENV['BASE_URI']).host if ENV['BASE_URI']
    hosts.compact
  rescue URI::InvalidURIError
    [request.host].compact
  end

  def ip_from_cloudflare
    request.env['HTTP_CF_CONNECTING_IP'] || request.env['HTTP_X_FORWARDED_FOR']
  end

  def visitor_country
    ISO3166::Country[request.env['HTTP_CF_IPCOUNTRY']]
  end

  def visitor_country_name
    visitor_country&.iso_short_name
  end

  def visitor_currency
    currency = visitor_country&.currency_code
    FIAT_CURRENCIES.include?(currency) ? currency : ENV['DEFAULT_CURRENCY']
  end

  def preferred_currency(account = current_account)
    if account && FIAT_CURRENCIES.include?(account.default_currency)
      account.default_currency
    else
      visitor_currency
    end
  end

  def current_account
    @current_account ||= @current_account_via_api_key || @current_account_via_ics_key || session_account
  end

  def event_method_in_organisation_currency(event, method, organisation)
    event.send(method).exchange_to(organisation.currency)
  rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
    0
  end

  # Resolve account by email from a public form: new rows are created as before; existing accounts are
  # only updated when the signed-in user is that same account. Guests and logged-in users acting for
  # someone else must not overwrite another person's profile.
  def save_or_update_account_from_email_form(account, attrs, model: Account)
    attrs ||= {}
    filtered = attrs.map { |k, v| [k, v] if v }.compact.to_h
    if account.persisted?
      return true unless current_account && current_account.id == account.id

      account.update_attributes(mass_assigning(filtered, model))
    else
      account.save
    end
  end

  # For rendering user-authored email HTML on our own domain
  def email_html_csp!
    headers['Content-Security-Policy'] = "default-src 'none'; img-src 'self' https: http: data:; style-src 'unsafe-inline'; script-src 'none'; object-src 'none'; base-uri 'none'"
  end

  def mass_assigning(params, model)
    params = (params || {}).dup
    # secret_block fields come back blank unless changed, so a blank one keeps the saved value unless Remove was ticked
    clear_secrets = Array(params.delete('clear_secrets')).map(&:to_s)
    if model.respond_to?(:secret_fields)
      model.secret_fields.each { |f| params.delete(f) if params.key?(f) && params[f].nil? && !clear_secrets.include?(f) }
      clear_secrets.each { |f| params[f] = nil if model.secret_fields.include?(f) }
    end
    if model.respond_to?(:protected_attributes)
      intersection = model.protected_attributes & params.keys.map(&:to_s)
      raise "Attributes #{intersection} are protected" unless intersection.empty?
    end
    params = params.to_h.transform_keys(&:to_s).slice(*model.form_attributes)
    # Each nested record is filtered with its own model, keeping the id and _destroy that find and remove it
    model.nested_attributes.each_key do |name|
      next unless params[name]

      child_model = model.relations[name.delete_suffix('_attributes')].klass
      filter_child = lambda do |attrs|
        attrs = attrs.to_h.transform_keys(&:to_s)
        mass_assigning(attrs.except('id', '_destroy'), child_model).merge(attrs.slice('id', '_destroy'))
      end
      # Forms send a hash of index => attributes; JSON can send an array
      params[name] = params[name].is_a?(Array) ? params[name].map(&filter_child) : params[name].to_h.transform_values(&filter_child)
    end
    params
  end

  # Works from total_entries, which will_paginate counts once, rather than loading the page:
  # on a Mongoid criteria, each to_a or count runs another query
  def pagination_details(collection, model: nil)
    total = collection.total_entries
    if collection.total_pages < 2
      case total
      when 0
        "No #{model.pluralize.downcase} found"
      when 1
        "Displaying <b>1</b> #{model.downcase}"
      else
        "Displaying <b>all #{total}</b> #{model.pluralize.downcase}"
      end
    else
      page_length = (total - collection.offset).clamp(0, collection.per_page)
      "Displaying #{model.pluralize.downcase} <b>#{collection.offset + 1} - #{collection.offset + page_length}</b> of <b>#{total}</b> in total"
    end
  end

  def set_time_zone
    Time.zone = if current_account && current_account.time_zone
                  current_account.time_zone
                elsif session[:time_zone]
                  session[:time_zone]
                elsif MaxMinder.reader && ip_from_cloudflare && (max_mind_time_zone = MaxMinder.reader.city(ip_from_cloudflare).location.time_zone)
                  session[:time_zone] = max_mind_time_zone
                else
                  ENV['DEFAULT_TIME_ZONE']
                end
  rescue MaxMind::GeoIP2::AddressNotFoundError
    Time.zone = ENV['DEFAULT_TIME_ZONE']
  rescue StandardError => e
    ErrorReporting.capture_exception(e)
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

  def organisation_from_params
    Organisation.find_by_slug_or_id(
      slug: params[:organisation_slug] || params[:slug],
      id: params[:organisation_id] || params[:id]
    )
  end

  def event_from_params
    Event.find_by_slug_or_id(
      slug: params[:event_slug] || params[:slug],
      id: params[:event_id] || params[:id]
    )
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
    hex == DEFAULT_THEME_COLOR.delete_prefix('#')
  end

  def resolved_event_theme_color(event)
    if event.theme_color && !theme_css_redundant?(event.theme_color)
      event.theme_color
    elsif event.organisation && !event.organisation.theme_background_color && event.organisation.theme_color && !theme_css_redundant?(event.organisation.theme_color)
      event.organisation.theme_color
    end
  end

  def resolve_feedback_account!
    @account = if admin? && params[:email]
                 Account.find_by(email: params[:email].downcase.strip)
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

  def cachebust(path)
    (digest = asset_digest(path)) ? "#{path}?#{digest}" : path
  end

  # The digest cachebust puts after a public file's path, or nil if there's no such file
  def asset_digest(path)
    # Files don't change after a production deploy, so skip the mtime check there
    return CACHEBUST_DIGESTS[path][1] if Padrino.env == :production && CACHEBUST_DIGESTS[path]

    file = File.join(settings.public_folder, path)
    return unless File.exist?(file)

    mtime = File.mtime(file)
    cached = CACHEBUST_DIGESTS[path]
    cached = CACHEBUST_DIGESTS[path] = [mtime, Digest::MD5.file(file).hexdigest[0..7]] unless cached && cached[0] == mtime
    cached[1]
  end
end
