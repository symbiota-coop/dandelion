# Field types the admin's search matches by regex, by number and by id, and every type it can search on
DADMIN_MATCHABLE_TYPES = { regex: %i[text text_area email url slug select], number: %i[number], id: %i[id] }.freeze
DADMIN_QUERYABLE_TYPES = (DADMIN_MATCHABLE_TYPES.values.flatten + %i[lookup check_box date datetime]).freeze

Dandelion::App.helpers do
  def dadmin_fields(model)
    admin_fields = model.admin_fields
    admin_fields[:created_at] = { type: :datetime, edit: false } if dadmin_persisted_field?(model, :created_at)
    admin_fields[:updated_at] = { type: :datetime, edit: false } if dadmin_persisted_field?(model, :updated_at)
    admin_fields = Hash[admin_fields.map do |fieldname, options|
                          options = { type: options } if options.is_a?(Symbol)
                          options[:index] = true if !options.keys.include?(:index) && DADMIN_QUERYABLE_TYPES.include?(options[:type])
                          options[:edit] = true unless options.keys.include?(:edit)
                          options[:disabled] = true if fieldname == :id
                          if %i[lookup
                                collection].include?(options[:type])
                            options[:class_name] = dadmin_assoc(model, fieldname, relationship: case options[:type]
                                                                                         when :lookup then :belongs_to
                                                                                         when :collection then :has_many
                                                                                                end).class_name
                          end
                          [fieldname, options]
                        end]
    admin_fields[admin_fields.first.first][:lookup] = true unless admin_fields.find do |_fieldname, options|
                                                                    options[:lookup]
                                                                  end
    admin_fields
  end

  def dadmin_assoc(model, fieldname, relationship: :belongs_to)
    case relationship
    when :belongs_to
      model.reflect_on_all_associations(:belongs_to).find { |assoc| assoc.foreign_key == fieldname.to_s }
    when :has_many
      model.reflect_on_all_associations(:has_many).find { |assoc| assoc.name == fieldname.to_sym }
    end
  end

  def dadmin_lookup_method(model)
    dadmin_fields(model).find { |_fieldname, options| options[:lookup] }.first
  end

  def dadmin_persisted_field?(model, fieldname)
    fieldname.to_s == 'id' || model.fields[fieldname.to_s]
  end

  # The condition for text search q matching a field of this type, or nil if it can't
  def dadmin_match(fieldname, type, q)
    if DADMIN_MATCHABLE_TYPES[:regex].include?(type)
      { fieldname => /#{Regexp.escape(q)}/i }
    elsif DADMIN_MATCHABLE_TYPES[:number].include?(type)
      { fieldname => q } if Float(q, exception: false)
    elsif DADMIN_MATCHABLE_TYPES[:id].include?(type)
      { fieldname => q }
    end
  end

  # Conditions for the index's text search, one per field it can match, to be ORed
  def dadmin_text_search(model, q)
    dadmin_fields(model).filter_map do |fieldname, options|
      if options[:type] == :lookup
        assoc_model = dadmin_assoc(model, fieldname).class_name.constantize
        assoc_fieldname = dadmin_lookup_method(assoc_model)
        next unless dadmin_persisted_field?(assoc_model, assoc_fieldname)

        condition = dadmin_match(assoc_fieldname, dadmin_fields(assoc_model)[assoc_fieldname][:type], q)
        { fieldname.to_sym.in => assoc_model.and(condition).pluck(:id) } if condition
      elsif dadmin_persisted_field?(model, fieldname)
        dadmin_match(fieldname, options[:type], q)
      end
    end
  end

  # One of the index's search criteria as a condition on the model's ids, or nil if it can't be applied.
  # fieldname can be a has-many collection's field, as collection.field
  def dadmin_criterion(model, fieldname, operator, value)
    if fieldname.include?('.')
      collection, fieldname = fieldname.split('.', 2)
      collection_assoc = dadmin_assoc(model, collection, relationship: :has_many) or return
      collection_model = collection_assoc.class_name.constantize
      key = collection_assoc.foreign_key.to_sym
    else
      collection_model = model
      key = :id
    end
    options = dadmin_fields(collection_model)[fieldname.to_sym] or return
    type = options[:type]
    return unless type == :lookup || dadmin_persisted_field?(collection_model, fieldname)

    value = nil if value == 'nil'
    ranged = false
    if DADMIN_MATCHABLE_TYPES[:regex].include?(type)
      value = /#{Regexp.escape(value)}/i if value
    elsif DADMIN_MATCHABLE_TYPES[:number].include?(type)
      return unless value.nil? || Float(value, exception: false)

      ranged = true
    elsif type == :check_box
      value = %w[true 1].include?(value.to_s.downcase)
    elsif %i[date datetime].include?(type)
      # Date.parse raises on nonsense and Time.zone.parse returns nil: either way, skip the criterion
      value = (type == :date ? Date.parse(value) : Time.zone.parse(value)) rescue return
      return unless value
      ranged = true
    elsif !(type == :lookup || DADMIN_MATCHABLE_TYPES[:id].include?(type))
      return
    end

    ids = case operator
          when :in, :nin then collection_model.and(fieldname => value).pluck(key)
          when :gt, :gte, :lt, :lte then collection_model.and(fieldname.to_sym.send(operator) => value).pluck(key) if ranged
          end
    return unless ids

    { :id.send(operator == :nin ? :nin : :in) => ids }
  end

  # The fields the index's criteria can search, with each has-many collection's own searchable fields under its name
  def dadmin_search_fields(model)
    searchable = ->(m, fieldname, options) { dadmin_persisted_field?(m, fieldname) && DADMIN_QUERYABLE_TYPES.include?(options[:type]) }
    dadmin_fields(model).filter_map do |fieldname, options|
      if options[:type] == :collection
        submodel = options[:class_name].constantize
        [fieldname, dadmin_fields(submodel).select { |f, o| searchable.(submodel, f, o) }]
      elsif searchable.(model, fieldname, options)
        [fieldname, options]
      end
    end.to_h
  end

  # The record a lookup field points to, or nil
  def dadmin_lookup_record(model, fieldname, resource)
    id = resource.send(fieldname) or return
    dadmin_assoc(model, fieldname).class_name.constantize.find(id)
  end

  # After saving or deleting: back to url, or in a popup, reload the page that opened it and close
  def dadmin_done(url)
    return redirect(url) unless params[:popup]

    '<script>window.opener.location.reload(false); window.close();</script>'
  end

end
