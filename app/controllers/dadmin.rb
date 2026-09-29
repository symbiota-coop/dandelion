# A generic admin for every model, at /dadmin
class OperatorNotSupported < StandardError; end

Dandelion::App.controller :dadmin do
  before do
    halt 403 if ENV['PERMITTED_IPS'] && (Padrino.env == :production) && !ENV['PERMITTED_IPS'].split(',').include?(request.ip)
    admins_only!
  end

  get :home, map: '/dadmin' do
    erb :'dadmin/home'
  end

  get :index, map: '/dadmin/index/:model', provides: %i[html json csv] do
    if persisted_field?(model, :created_at)
      @o = :created_at
      @d = :desc
    end
    if model.respond_to?(:filter_options)
      @o = model.filter_options[:o]
      @d = model.filter_options[:d]
    end
    @id = params[:id] if params[:id]
    @q = params[:q] if params[:q]
    @o = params[:o].to_sym if params[:o]
    @d = params[:d].to_sym if params[:d]
    @resources = model.all
    @resources = @resources.where(id: @id) if @id

    if @q
      query = []
      admin_fields(model).each do |fieldname, options|
        if options[:type] === :lookup
          assoc_name = assoc_name(model, fieldname)
          assoc_model = assoc_name.constantize
          assoc_fields = admin_fields(assoc_model)
          assoc_fieldname = lookup_method(assoc_model)
          assoc_options = assoc_fields[assoc_fieldname]
          if persisted_field?(assoc_model, assoc_fieldname)
            if matchable_regex.include?(assoc_options[:type])
              query << { fieldname.to_sym.in => assoc_model.where(assoc_fieldname => /#{Regexp.escape(@q)}/i).pluck(:id) }
            elsif matchable_number.include?(assoc_options[:type]) && (begin
 Float(@q) && true; rescue StandardError; false; end)
              query << { fieldname.to_sym.in => assoc_model.where(assoc_fieldname => @q).pluck(:id) }
            elsif matchable_id.include?(assoc_options[:type])
              query << { fieldname.to_sym.in => assoc_model.where(assoc_fieldname => @q).pluck(:id) }
            end
          end
        elsif persisted_field?(model, fieldname)
          if matchable_regex.include?(options[:type])
            query << { fieldname => /#{Regexp.escape(@q)}/i }
          elsif matchable_number.include?(options[:type]) && (begin
 Float(@q) && true; rescue StandardError; false; end)
            query << { fieldname => @q }
          elsif matchable_id.include?(options[:type])
            query << { fieldname => @q }
          end
        end
      end
      @resources = @resources.and('$or' => query)
    end

    query = []
    if params[:qk]
      params[:qk].each_with_index do |fieldname, i|
        q = params[:qv][i]
        q = nil if q == 'nil'
        b = params[:qb][i].to_sym
        if !fieldname.include?('.')
          collection_model = model
          collection_key = :id
        else
          collection, fieldname = fieldname.split('.')
          collection_assoc = assoc(model, collection, relationship: :has_many)
          collection_model = collection_assoc.class_name.constantize
          collection_key = collection_assoc.inverse_foreign_key.to_sym
        end
        options = admin_fields(collection_model)[fieldname.to_sym]
        if options[:type] == :lookup
          case b
          when :in
            query << { :id.in => collection_model.where(fieldname => q).pluck(collection_key) }
          when :nin
            query << { :id.nin => collection_model.where(fieldname => q).pluck(collection_key) }
          when :gt, :gte, :lt, :lte
            raise OperatorNotSupported
          end
        elsif persisted_field?(collection_model, fieldname)
          if matchable_regex.include?(options[:type])
            case b
            when :in
              if q.nil?
                query << { :id.in => collection_model.where(fieldname => nil).pluck(collection_key) }
              else
                query << { :id.in => collection_model.where(fieldname => /#{Regexp.escape(q)}/i).pluck(collection_key) }
              end
            when :nin
              if q.nil?
                query << { :id.nin => collection_model.where(fieldname => nil).pluck(collection_key) }
              else
                query << { :id.nin => collection_model.where(fieldname => /#{Regexp.escape(q)}/i).pluck(collection_key) }
              end
            when :gt, :gte, :lt, :lte
              raise OperatorNotSupported
            end
          elsif matchable_number.include?(options[:type]) && (begin
 Float(q) && true; rescue StandardError; false; end || q.nil?)
            case b
            when :in
              query << { :id.in => collection_model.where(fieldname => q).pluck(collection_key) }
            when :nin
              query << { :id.nin => collection_model.where(fieldname => q).pluck(collection_key) }
            when :gt, :gte, :lt, :lte
              query << { :id.in => collection_model.where(fieldname.to_sym.send(b) => q).pluck(collection_key) }
            end
          elsif matchable_id.include?(options[:type])
            case b
            when :in
              query << { :id.in => collection_model.where(fieldname => q).pluck(collection_key) }
            when :nin
              query << { :id.nin => collection_model.where(fieldname => q).pluck(collection_key) }
            end
          elsif options[:type] == :check_box
            checkbox_value = case q.to_s.downcase
                            when 'true', '1' then true
                            when 'false', '0', '' then false
                            else false
                            end
            case b
            when :in
              query << { :id.in => collection_model.where(fieldname => checkbox_value).pluck(collection_key) }
            when :nin
              query << { :id.nin => collection_model.where(fieldname => checkbox_value).pluck(collection_key) }
            when :gt, :gte, :lt, :lte
              raise OperatorNotSupported
            end
          elsif options[:type] == :date
            case b
            when :in
              query << { :id.in => collection_model.where(fieldname => Date.parse(q)).pluck(collection_key) }
            when :nin
              query << { :id.nin => collection_model.where(fieldname => Date.parse(q)).pluck(collection_key) }
            when :gt, :gte, :lt, :lte
              query << { :id.in => collection_model.where(fieldname.to_sym.send(b) => Date.parse(q)).pluck(collection_key) }
            end
          elsif options[:type] == :datetime
            case b
            when :in
              query << { :id.in => collection_model.where(fieldname => Time.zone.parse(q)).pluck(collection_key) }
            when :nin
              query << { :id.nin => collection_model.where(fieldname => Time.zone.parse(q)).pluck(collection_key) }
            when :gt, :gte, :lt, :lte
              query << { :id.in => collection_model.where(fieldname.to_sym.send(b) => Time.zone.parse(q)).pluck(collection_key) }
            end
          end
        end
      end
    end

    case params[:all_any]
    when 'all'
      @resources = @resources.and(query)
    when 'any'
      @resources = @resources.and('$or' => query)
    end

    @resources = @resources.order_by(@o => @d) if @o && @d
    case content_type
    when :html
      @resources = @resources.paginate(page: params[:page], per_page: 25)
      instance_variable_set("@#{model.to_s.underscore.gsub('/', '_').pluralize}", @resources)
      erb :'dadmin/index'
    when :json
      {
        results: @resources.map do |resource|
                   { id: resource.id.to_s,
                     text: "#{resource.send(lookup_method(resource.class))} (id:#{resource.id})" }
                 end
      }.to_json
    when :csv
      fields = admin_fields(model).select { |_fieldname, options| options[:index] }
      CSV.generate do |csv|
        csv << fields.keys
        @resources.each do |resource|
          csv << fields.map do |fieldname, options|
            if (options[:type] === :lookup) && resource.send(fieldname)
              assoc_name = assoc_name(model, fieldname)
              "#{r = assoc_name.constantize.find(resource.send(fieldname)); r ? r.send(lookup_method(assoc_name.constantize)) : resource.send(fieldname)} (id:#{resource.send(fieldname)})"
            elsif %i[date datetime].include?(options[:type])
              resource.send(fieldname).try(:iso8601)
            else
              resource.send(fieldname)
            end
          end
        end
      end
    end
  end

  get :new, map: '/dadmin/new/:model' do
    @resource = model.new
    instance_variable_set("@#{model.to_s.underscore.gsub('/', '_')}", @resource)
    erb :'dadmin/build'
  end

  post :new, map: '/dadmin/new/:model' do
    @resource = model.new(params[model.to_s.underscore.gsub('/', '_')])
    instance_variable_set("@#{model.to_s.underscore.gsub('/', '_')}", @resource)
    if @resource.save
      flash[:notice] = "<strong>Awesome!</strong> The #{human_model_name(model).downcase} was created successfully."
      params[:popup] ? refreshParent : redirect(url(:dadmin, :index, model: model.to_s))
    else
      flash.now[:error] =
        "<strong>Oops.</strong> Some errors prevented the #{human_model_name(model).downcase} from being saved."
      erb :'dadmin/build'
    end
  end

  get :edit, map: '/dadmin/edit/:model/:id' do
    @resource = model.find(params[:id])
    instance_variable_set("@#{model.to_s.underscore.gsub('/', '_')}", @resource)
    erb :'dadmin/build'
  end

  post :edit, map: '/dadmin/edit/:model/:id' do
    @resource = model.find(params[:id])
    instance_variable_set("@#{model.to_s.underscore.gsub('/', '_')}", @resource)
    if @resource.update_attributes(params[model.to_s.underscore.gsub('/', '_')])
      flash[:notice] =
        "<strong>Sweet!</strong> The #{human_model_name(model).downcase} was updated successfully."
      params[:popup] ? refreshParent : redirect(url(:dadmin, :edit, model: model.to_s, id: @resource.id))
    else
      flash.now[:error] =
        "<strong>Oops.</strong> Some errors prevented the #{human_model_name(model).downcase} from being saved."
      erb :'dadmin/build'
    end
  end

  post :destroy, map: '/dadmin/destroy/:model/:id' do
    resource = model.find(params[:id])
    if resource.destroy
      flash[:notice] = "<strong>Boom!</strong> The #{human_model_name(model).downcase} was deleted."
    else
      flash[:error] = "<strong>Darn!</strong> The #{human_model_name(model).downcase} couldn't be deleted."
    end
    params[:popup] ? refreshParent : redirect(url(:dadmin, :index, model: model.to_s))
  end
end

Dandelion::App.helpers do
  def models
    if ENV['ADMIN_MODELS']
      (ENV['ADMIN_MODELS'].split(',').map do |x|
         x.constantize
       end)
    else
      (Dir.entries("#{PADRINO_ROOT}/models").select do |filename|
         filename.ends_with?('.rb')
       end.map do |filename|
         filename.split('.rb').first.camelize.constantize
       end)
    end
  end

  def model
    allowed = models.map(&:to_s)
    redirect('/') unless allowed.include?(params[:model])
    params[:model].constantize
  end

  def admin_fields(model)
    admin_fields = model.admin_fields
    admin_fields[:created_at] = { type: :datetime, edit: false } if persisted_field?(model, :created_at)
    admin_fields[:updated_at] = { type: :datetime, edit: false } if persisted_field?(model, :updated_at)
    admin_fields = Hash[admin_fields.map do |fieldname, options|
                          options = { type: options } if options.is_a?(Symbol)
                          options[:index] = true if !options.keys.include?(:index) && queryable.include?(options[:type])
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

  def assoc_name(model, fieldname)
    assoc(model, fieldname).class_name
  end

  def lookup_method(model)
    admin_fields(model).find { |_fieldname, options| options[:lookup] }.first
  end

  def persisted_field?(model, fieldname)
    fieldname.to_s == 'id' || model.fields[fieldname.to_s]
  end

  def matchable_regex
    %i[text text_area email url slug select]
  end

  def matchable_number
    [:number]
  end

  def matchable_id
    [:id]
  end

  def queryable
    matchable_regex + matchable_number + matchable_id + %i[lookup check_box date datetime]
  end

  def human_model_name(model)
    model.to_s.underscore.gsub('/', '_').humanize
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
