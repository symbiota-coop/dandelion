Dandelion::App.helpers do
  def partial(*args)
    if admin? && !args.first.to_s.starts_with?('icons')
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

  def cp(slug, locals: {}, event: nil, key: slug, expires: 1.hour.from_now)
    if Padrino.env == :development
      partial(slug, locals: locals)
    else
      if (fragment = Fragment.find_by(key: key)) && fragment.expires > Time.now
        fragment.value
      else
        fragment.try(:destroy)
        begin
          Fragment.create(event: event, key: key, value: partial(slug, locals: locals), expires: expires).value
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
end
