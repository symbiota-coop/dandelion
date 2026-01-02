# rubocop:disable Naming/MethodParameterName
Dandelion::App.helpers do
  def search_type_config
    {
      Event => {
        scope: -> { Event.live.public.browsable.future(1.month.ago) },
        icon: 'bi-calendar-event',
        redirect_path: ->(item) { "/e/#{item.slug}" },
        label_formatter: ->(item) { "#{item.name} (#{concise_when_details(item)})" }
      },
      Account => {
        scope: -> { Account.public },
        icon: 'bi-person-fill',
        redirect_path: ->(item) { params[:message] ? "/messages/#{item.id}" : "/u/#{item.username}" },
        label_formatter: ->(item) { item.name }
      },
      Organisation => {
        scope: -> { Organisation.all },
        icon: 'bi-flag-fill',
        redirect_path: ->(item) { "/o/#{item.slug}" },
        label_formatter: ->(item) { item.name }
      },
      Gathering => {
        scope: -> { Gathering.and(listed: true).and(:privacy.ne => 'secret') },
        icon: 'bi-moon-fill',
        redirect_path: ->(item) { "/g/#{item.slug}" },
        label_formatter: ->(item) { item.name }
      }
    }
  end

  def search_type_to_model(type_string)
    type_string&.classify&.constantize
  rescue NameError
    nil
  end

  def model_to_search_type(model_class)
    model_class.name.underscore.pluralize
  end

  def search_prefix(model_class)
    model_class.name.underscore
  end

  def perform_ajax_search(q, model_class = nil)
    results = []

    search_type_config.each do |config_model_class, config|
      next if model_class && config_model_class != model_class

      scope = config[:scope].call
      items = config_model_class.search(q, scope, limit: 5, build_records: true, phrase_boost: 1.5, text_search: true, vector_weight: 0.5)
      prefix = search_prefix(config_model_class)
      results += items.map do |item|
        {
          label: %(<i class="bi #{config[:icon]}"></i> #{config[:label_formatter].call(item)}),
          value: %(#{prefix}:"#{item.name}")
        }
      end
    end

    results
  end

  def perform_full_search(q, model_class)
    config = search_type_config[model_class]
    return unless config

    scope = config[:scope].call
    prefix = search_prefix(model_class)
    var_name = "@#{model_to_search_type(model_class)}"

    # Handle exact match redirects (check original params[:q] for prefix)
    if params[:q]&.starts_with?("#{prefix}:")
      exact_scope = scope.and(name: q)
      redirect config[:redirect_path].call(exact_scope.first) if exact_scope.count == 1
    end

    # Perform search
    results = model_class.search(q, scope, build_records: true, phrase_boost: 1.5, text_search: true, vector_weight: 0.5)

    # Deduplicate events by name and location, keeping only the first result for each combination
    results = results.uniq { |e| [e.name, e.location] } if model_class == Event

    instance_variable_set(var_name, results.paginate(page: params[:page], per_page: 20))
  end

  def parse_search_query(q)
    return [nil, q] unless q

    search_type_config.each_key do |model_class|
      prefix = search_prefix(model_class)
      next unless q.starts_with?("#{prefix}:")

      # If it doesn't have quotes, add them around the value
      q = q.sub(/#{prefix}:\s*(.+)/, "#{prefix}:\"\\1\"") unless q.match?(/#{prefix}\s*:"/)
      match = q.match(/#{prefix}\s*:"(.+)"/)
      return [model_to_search_type(model_class), match[1].strip] if match
    end

    [nil, q]
  end
end
# rubocop:enable Naming/MethodParameterName
