Dandelion::App.helpers do
  def airbrake_notify(error, extra = {})
    raise(error) if Padrino.env == :development

    Airbrake.notify(error,
                    url: "#{ENV['BASE_URI']}#{request.path}",
                    current_account: (JSON.parse(current_account.to_json) if current_account),
                    params: params,
                    request: request.env.select { |_k, v| v.is_a?(String) },
                    session: session,
                    extra: extra)
  end

  def env_yaml
    request.env.select { |_k, v| v.is_a?(String) }.to_yaml
  end

  def concise_when_details(whenable, with_zone: false)
    whenable.send(:concise_when_details, current_account ? current_account.time_zone : session[:time_zone], with_zone: with_zone)
  end

  def when_details(whenable, with_zone: true)
    whenable.send(:when_details, current_account ? current_account.time_zone : session[:time_zone], with_zone: with_zone)
  end

  def search(klass, match, query, number = nil)
    if Padrino.env == :development
      klass.or(klass.admin_fields.map { |k, v| { k => /#{Regexp.escape(query)}/i } if v == :text || (v.is_a?(Hash) && v[:type] == :text) }.compact)
    else
      pipeline = [{ '$search': { index: klass.to_s.underscore.pluralize, text: { query: query, path: { wildcard: '*' } } } }, { '$match': match.selector }]
      aggregate = klass.collection.aggregate(pipeline)
      aggregate = aggregate.first(number) if number
      aggregate.map do |hash|
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
    Event.all.or(
      { name: /#{Regexp.escape(query)}/i },
      { description: /#{Regexp.escape(query)}/i }
    )
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
      output = super(*args)
      t2 = Time.now
      ms = ((t2 - t1) * 1000).round
      t = "<script>console.log('PARTIAL #{ms.times.map { '=' }.join} #{args.first} #{ms}ms')</script>".html_safe
      output + t
    else
      super(*args)
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
    (0..count - 1).sort_by { rand }.slice(0, number).collect! { |i| relation.skip(i).first }
  end

  def timeago(time)
    %(<abbr class="timeago" title="#{time.iso8601}">#{time}</abbr>).html_safe
  end

  def checkbox(name, slug: nil, checked: false)
    slug ||= name.force_encoding('utf-8').parameterize.underscore
    %(<div class="form-group">
         <div class="checkbox-inline">
            #{check_box_tag :"#{slug}", checked: checked || params[:"#{slug}"], id: "#{slug}_checkbox"}
            <label for="#{slug}_checkbox">#{name}</label>
          </div>
      </div>).html_safe
  end

  def generate_nolt_token
    payload = {
      id: current_account.id.to_s,
      email: current_account.email,
      name: current_account.name,
      imageUrl: (current_account.picture.url if current_account.picture)
    }
    JWT.encode(payload, ENV['NOLT_SSO_SECRET'], 'HS256')
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
end
