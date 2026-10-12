Dandelion::App.helpers do
  def partial(*args)
    partial_name = args.first.to_s
    Sentry.with_child_span(op: 'template.render', description: partial_name) do
      super(*args)
    end
  end

  # Caches a partial, or with a block, whatever the block returns (e.g. cp(key: '/events.ics') { build_events_ical(...) })
  def cp(slug = nil, locals: {}, event: nil, key: slug, expires: 1.hour.from_now)
    render = -> { block_given? ? yield : partial(slug, locals: locals) }
    if Padrino.env == :development
      render.call
    else
      fragment = @fragments && @fragments.key?(key) ? @fragments[key] : Fragment.find_by(key: key)
      if fragment && fragment.expires > Time.now
        fragment.value
      else
        fragment.try(:destroy)
        begin
          Fragment.create(event: event, key: key, value: render.call, expires: expires).value
        rescue Mongo::Error::OperationFailure # protect against race condition
          Fragment.find_by(key: key).value
        end
      end.html_safe
    end
  end

  # Loads the fragments for keys in one query, for cp to use rather than querying each key itself
  def prefetch_fragments(keys)
    @fragments = keys.index_with(nil).merge(Fragment.and(:key.in => keys).index_by(&:key))
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
