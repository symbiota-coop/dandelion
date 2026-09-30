# Field types the admin's search matches by regex, by number and by id, and every type it can search on
DADMIN_MATCHABLE_TYPES = { regex: %i[text text_area email url slug select], number: %i[number], id: %i[id] }.freeze
DADMIN_QUERYABLE_TYPES = (DADMIN_MATCHABLE_TYPES.values.flatten + %i[lookup check_box date datetime]).freeze

Dandelion::App.helpers do
  def admin_fields(model)
    admin_fields = model.admin_fields
    admin_fields[:created_at] = { type: :datetime, edit: false } if persisted_field?(model, :created_at)
    admin_fields[:updated_at] = { type: :datetime, edit: false } if persisted_field?(model, :updated_at)
    admin_fields = Hash[admin_fields.map do |fieldname, options|
                          options = { type: options } if options.is_a?(Symbol)
                          options[:index] = true if !options.keys.include?(:index) && DADMIN_QUERYABLE_TYPES.include?(options[:type])
                          options[:edit] = true unless options.keys.include?(:edit)
                          options[:disabled] = true if fieldname == :id
                          if %i[lookup
                                collection].include?(options[:type])
                            options[:class_name] = assoc(model, fieldname, relationship: case options[:type]
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

  def assoc(model, fieldname, relationship: :belongs_to)
    case relationship
    when :belongs_to
      model.reflect_on_all_associations(:belongs_to).find { |assoc| assoc.foreign_key == fieldname.to_s }
    when :has_many
      model.reflect_on_all_associations(:has_many).find { |assoc| assoc.name == fieldname.to_sym }
    end
  end

  def lookup_method(model)
    admin_fields(model).find { |_fieldname, options| options[:lookup] }.first
  end

  def persisted_field?(model, fieldname)
    fieldname.to_s == 'id' || model.fields[fieldname.to_s]
  end

  def refreshParent
    '
      <script>
      window.opener.location.reload(false);
      window.close();
      </script>
    '
  end

end
