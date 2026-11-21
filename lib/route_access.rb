# Who may use a route, given as its access: option: get '/terms', access: :public do. Padrino sends each route option it
# doesn't know to the app, which makes this a condition the route checks before its body runs, after the app's and the
# controller's before filters (so after signing in from an emailed link or code). Levels that need a record (an event's
# admins, a gathering's members...) are the guards in app/helpers/access_control.rb, called in the route's body once
# it has found the record. Dandelion/RouteAccess fails a route that has neither (AGENTS.md, Conventions)
module RouteAccess
  # public: anyone, said explicitly; signed_in: sign_in_required!; admin: admins_only! (site admins)
  LEVELS = %i[public signed_in admin].freeze

  def access(level)
    raise ArgumentError, "access: #{level.inspect} isn't one of #{LEVELS.map(&:inspect).join(', ')}" unless LEVELS.include?(level)

    case level
    when :signed_in then condition { sign_in_required! || true }
    when :admin then condition { admins_only! || true }
    end
  end
end
