Dandelion::App.helpers do
  def ip_from_cloudflare
    request.env['HTTP_CF_CONNECTING_IP'] || request.env['HTTP_X_FORWARDED_FOR']
  end

  def md(text, hard_wrap: false)
    markdown = Redcarpet::Markdown.new(hard_wrap ? Redcarpet::Render::HTML.new(hard_wrap: true) : Redcarpet::Render::HTML, autolink: true, tables: true, fenced_code_blocks: true)
    markdown.render(text)
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

  def env_yaml
    request.env.select { |k, v| v.is_a?(String) && k != 'rack.request.form_vars' }.to_yaml
  end

  def concise_when_details(whenable, with_zone: false)
    whenable.send(:concise_when_details, current_account ? current_account.time_zone : session[:time_zone], with_zone: with_zone)
  end

  def when_details(whenable, with_zone: true)
    whenable.send(:when_details, current_account ? current_account.time_zone : session[:time_zone], with_zone: with_zone)
  end

  def search(klass, match, query, number)
    if Padrino.env == :development
      klass.or(klass.admin_fields.map { |k, v| { k => /#{Regexp.escape(query)}/i } if v == :text || (v.is_a?(Hash) && v[:type] == :text) }.compact)
    else
      pipeline = [
        { '$search': {
          index: klass.to_s.underscore.pluralize,
          compound: {
            should: [
              { phrase: { query: query, path: { wildcard: '*' }, score: { boost: { value: 1.5 } } } },
              { text: { query: query, path: { wildcard: '*' } } }
            ]
          }
        } },
        { '$addFields': { score: { '$meta': 'searchScore' } } },
        { '$match': match.selector }
      ]

      results = klass.collection.aggregate(pipeline).first(number)

      # Filter by score threshold (50% of max score)
      if results.any?
        max_score = results.map { |doc| doc['score'] }.max
        min_score = max_score * 0.5
        results = results.select { |doc| doc['score'] >= min_score }
      end

      results.map do |hash|
        klass.new(hash.select { |k, _v| klass.fields.keys.include?(k.to_s) })
      end
    end
  end

  def search_accounts(query)
    Account.all.or(
      { name: /#{Regexp.escape(query)}/i },
      { name_transliterated: /#{Regexp.escape(query)}/i },
      { email: /#{Regexp.escape(query)}/i },
      { username: /#{Regexp.escape(query)}/i }
    )
  end

  def search_events(query)
    # Mongoid::Paranoia seems to break .or
    Event.where('$or' => [
                  { name: /#{Regexp.escape(query)}/i },
                  { description: /#{Regexp.escape(query)}/i },
                  { location: /#{Regexp.escape(query)}/i },
                  { event_tags_joined: /#{Regexp.escape(query)}/i }
                ])
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

  def partial(*args)
    if admin?
      t1 = Time.now
      output = super
      t2 = Time.now
      ms = ((t2 - t1) * 1000).round
      t = "<script>console.log('PARTIAL #{ms.times.map { '=' }.join} #{args.first} #{ms}ms')</script>".html_safe
      output + t
    else
      super
    end
  end

  def cp(slug, locals: {}, key: slug, expires: 1.hour.from_now)
    if Padrino.env == :development
      partial(slug, locals: locals)
    else
      if (fragment = Fragment.find_by(key: key)) && fragment.expires > Time.now
        fragment.value
      else
        fragment.try(:destroy)
        begin
          Fragment.create(key: key, value: partial(slug, locals: locals), expires: expires).value
        rescue Mongo::Error::OperationFailure # protect against race condition
          Fragment.find_by(key: key).value
        end
      end.html_safe
    end
  end

  def stash_partial(slug, locals: {}, key: slug)
    # if Padrino.env == :development
    #   partial(slug, locals: locals)
    # else
    if (stash = Stash.find_by(key: key))
      stash.value
    else
      begin
        Stash.create(key: key, value: partial(slug, locals: locals)).value
      rescue Mongo::Error::OperationFailure # protect against race condition
        Stash.find_by(key: key).value
      end
    end.html_safe
    # end
  end

  def mass_assigning(params, model)
    params ||= {}
    if model.respond_to?(:protected_attributes)
      intersection = model.protected_attributes & params.keys
      raise "attributes #{intersection} are protected" unless intersection.empty?
    end
    params
  end

  def current_account
    @current_account ||= Account.find(session[:account_id]) if session[:account_id]
  end

  def m(amount, currency)
    if amount.is_a?(Money)
      amount.exchange_to(currency).format(no_cents_if_whole: true)
    else
      Money.new(amount * 100, currency).format(no_cents_if_whole: true)
    end
  rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
    "#{currency} #{amount}"
  end

  def calculate_geographic_bounding_box(location_query)
    return nil unless location_query && (result = Geocoder.search(location_query).first)

    bounds = nil
    if result.respond_to?(:boundingbox) && result.boundingbox
      bounds = true
      south, north, west, east = result.boundingbox.map(&:to_f)
    elsif result.respond_to?(:bounds) && result.bounds
      bounds = true
      if ['uk', 'united kingdom'].include?(location_query.downcase)
        south = 49.6740000
        west = -14.0155170
        north = 61.0610000
        east = 2.0919117
      else
        south, west, north, east = result.bounds.map(&:to_f)
      end
    end

    # Always ensure minimum 25km bounding box
    lat, lng = result.coordinates
    min_km = 25
    # Approximate degrees per kilometer (varies by latitude, but good enough for a 25km box)
    lat_offset = (min_km / 2) * 0.009 # ~1km = 0.009 degrees latitude
    lng_offset = (min_km / 2) * 0.009 / Math.cos(lat * Math::PI / 180) # Adjust for longitude compression at this latitude

    min_south = lat - lat_offset
    min_north = lat + lat_offset
    min_west = lng - lng_offset
    min_east = lng + lng_offset

    if bounds
      # Expand bounds if they're smaller than 25km
      south = [south, min_south].min
      north = [north, min_north].max
      west = [west, min_west].min
      east = [east, min_east].max
    else
      # Use the 25km box as fallback
      south = min_south
      north = min_north
      west = min_west
      east = min_east
    end

    [[west, south], [east, north]]
  end

  def money_symbol(currency)
    Money.new(0, currency).symbol
  rescue Money::Currency::UnknownCurrency
    currency
  end

  def u(url)
    URI::Parser.new.escape(url) if url
  end

  def random(relation, number)
    count = relation.count
    (0..(count - 1)).sort_by { rand }.slice(0, number).collect! { |i| relation.skip(i).first }
  end

  def timeago(time)
    %(<abbr class="timeago" title="#{time.iso8601}">#{time}</abbr>).html_safe
  end

  def checkbox(name, slug: nil, checked: false, form_group_class: nil, disabled: false)
    slug ||= name.force_encoding('utf-8').parameterize.underscore
    checked_or_param = checked || params[:"#{slug}"]
    %(<div class="form-group #{form_group_class}">
         <div class="checkbox-inline #{'checked' if checked_or_param}">
            #{check_box_tag :"#{slug}", checked: checked_or_param, id: "#{slug}_checkbox", disabled: disabled}
            <label for="#{slug}_checkbox">#{name}</label>
          </div>
      </div>).html_safe
  end

  def parse_date(date)
    Date.parse(date)
  rescue Date::Error
    nil
  end

  def money_sort(event, organisation, method)
    event.send(method).exchange_to(organisation.currency)
  rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
    0
  end

  def youtube_embed_url(url)
    if url =~ %r{(?:youtube\.com/(?:[^/]+/.+/|(?:v|e(?:mbed)?)/|.*[?&]v=)|youtu\.be/)([^"&?/\s]{11})}
      "https://www.youtube.com/embed/#{Regexp.last_match(1)}"
    else
      url # Return original URL if it doesn't match YouTube format
    end
  end

  def monthly_contribution_data(currency = nil)
    currency ||= ENV['DEFAULT_CURRENCY'] || 'GBP'
    fragment = Fragment.find_by(key: 'monthly_contributions')

    return nil unless fragment&.value

    monthly_data = JSON.parse(fragment.value)
    current_month = "#{Date::MONTHNAMES[Date.today.month]} #{Date.today.year}"
    current_month_data = monthly_data.find { |d| d[0] == current_month }

    return nil unless current_month_data

    monthly_contributions = Money.new(current_month_data[1] * 100, 'GBP')
    monthly_contributions = monthly_contributions.exchange_to(currency)

    return nil unless monthly_contributions > 0

    current_month_value = monthly_contributions.to_i
    days_in_month = Date.new(Date.today.year, Date.today.month, -1).day
    days_passed = Date.today.day
    projected_value = (current_month_value.to_f / days_passed * days_in_month).round

    {
      current: monthly_contributions,
      projected: projected_value,
      currency: currency
    }
  end

  def map_json(points)
    box = [[params[:west].to_f, params[:south].to_f], [params[:east].to_f, params[:north].to_f]]
    points = points.and(coordinates: { '$geoWithin' => { '$box' => box } })

    {
      points: if points.count > 500
                []
              else
                points.map.with_index do |point, n|
                  {
                    model_name: point.class.to_s,
                    id: point.id.to_s,
                    lat: point.lat,
                    lng: point.lng,
                    n: n
                  }
                end
              end,
      pointsCount: points.count
    }.to_json
  end

  def calendar_json(events)
    user_time_zone = current_account ? current_account.time_zone : session[:time_zone]
    events.map do |event|
      {
        id: event.id.to_s,
        name: event.name,
        start_time: event.start_time.iso8601,
        end_time: event.end_time.iso8601,
        slug: event.slug,
        location: event.location,
        when_details: event.when_details(user_time_zone)
      }
    end.to_json
  end
end
