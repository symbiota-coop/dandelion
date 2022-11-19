Dandelion::App.helpers do
  def env_yaml
    request.env.select { |_k, v| v.is_a?(String) }.to_yaml
  end

  def concise_when_details(whenable)
    whenable.send(:concise_when_details, current_account ? current_account.time_zone : session[:time_zone])
  end

  def when_details(whenable)
    whenable.send(:when_details, current_account ? current_account.time_zone : session[:time_zone])
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
    if (fragment = Fragment.find_by(key: key)) && fragment.expires > Time.now
      fragment.value
    else
      fragment.try(:destroy)
      begin
        Fragment.create(key: key, value: partial(slug, locals: locals), expires: expires).value
      rescue Mongo::Error::OperationFailure
        Fragment.find_by(key: key).try(:value)
      end
    end.html_safe
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
  end

  def u(url)
    URI::Parser.new.escape(url) if url
  end

  def random(relation, n)
    count = relation.count
    (0..count - 1).sort_by { rand }.slice(0, n).collect! { |i| relation.skip(i).first }
  end

  def timeago(x)
    %(<abbr class="timeago" title="#{x.iso8601}">#{x}</abbr>).html_safe
  end

  def checkbox(name, slug: nil, checked: false)
    slug ||= name.force_encoding('utf-8').parameterize.underscore
    %(<div class="form-group">
         <div class="checkbox-inline">
            #{check_box_tag :"#{slug}", checked: (checked || params[:"#{slug}"]), id: "#{slug}_checkbox"}
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
end
