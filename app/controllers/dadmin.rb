# A generic admin for every model, at /dadmin
Dandelion::App.controller :dadmin do
  before do
    admins_only!
    if params[:model]
      redirect(url(:dadmin, :home)) unless AppModels.all.map(&:to_s).include?(params[:model])
      @model = params[:model].constantize
      @model_name = @model.model_name.human.downcase
    end
  end

  get :home, map: '/dadmin' do
    erb :'dadmin/home'
  end

  get :index, map: '/dadmin/index/:model', provides: %i[html json csv] do
    @o, @d = :created_at, :desc if dadmin_persisted_field?(@model, :created_at)
    @o, @d = @model.filter_options.values_at(:o, :d) if @model.respond_to?(:filter_options)
    @o = params[:o].to_sym if params[:o]
    @d = params[:d].to_sym if params[:d]
    @id = params[:id]
    @q = params[:q]

    @resources = @model.all
    @resources = @resources.and(id: @id) if @id
    if @q
      conditions = dadmin_text_search(@model, @q)
      @resources = conditions.any? ? @resources.and('$or' => conditions) : @resources.none
    end

    criteria = Array(params[:qk]).each_with_index.filter_map do |fieldname, i|
      dadmin_criterion(@model, fieldname, params[:qb][i].to_sym, params[:qv][i])
    end
    if criteria.any?
      case params[:all_any]
      when 'all'
        @resources = @resources.and(criteria)
      when 'any'
        @resources = @resources.and('$or' => criteria)
      end
    end

    @resources = @resources.order_by(@o => @d) if @o && @d
    @index_fields = dadmin_fields(@model).select { |_fieldname, options| options[:index] }
    case content_type
    when :html
      @resources = @resources.paginate(page: params[:page], per_page: 25)
      erb :'dadmin/index'
    when :json
      {
        results: @resources.map do |resource|
          { id: resource.id.to_s, text: "#{resource.send(dadmin_lookup_method(resource.class))} (id:#{resource.id})" }
        end
      }.to_json
    when :csv
      CSV.generate do |csv|
        csv << @index_fields.keys
        @resources.each do |resource|
          csv << @index_fields.map do |fieldname, options|
            if options[:type] == :lookup && (id = resource.send(fieldname))
              record = dadmin_lookup_record(@model, fieldname, resource)
              "#{record ? record.send(dadmin_lookup_method(record.class)) : id} (id:#{id})"
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
    @resource = @model.new
    # Links to new records can prefill lookups, as in ?event_id=...
    dadmin_fields(@model).each do |fieldname, options|
      @resource.send("#{fieldname}=", params[fieldname]) if options[:type] == :lookup && params[fieldname]
    end
    erb :'dadmin/build'
  end

  post :new, map: '/dadmin/new/:model' do
    @resource = @model.new(params[@model.model_name.param_key])
    if @resource.save
      flash[:notice] = "The #{@model_name} was created."
      dadmin_done(url(:dadmin, :index, model: @model.to_s))
    else
      flash.now[:error] = "Some errors prevented the #{@model_name} from being saved."
      erb :'dadmin/build'
    end
  end

  get :edit, map: '/dadmin/edit/:model/:id' do
    @resource = @model.find(params[:id])
    erb :'dadmin/build'
  end

  post :edit, map: '/dadmin/edit/:model/:id' do
    @resource = @model.find(params[:id])
    if @resource.update_attributes(params[@model.model_name.param_key])
      flash[:notice] = "The #{@model_name} was updated."
      dadmin_done(url(:dadmin, :edit, model: @model.to_s, id: @resource.id))
    else
      flash.now[:error] = "Some errors prevented the #{@model_name} from being saved."
      erb :'dadmin/build'
    end
  end

  post :destroy, map: '/dadmin/destroy/:model/:id' do
    if @model.find(params[:id]).destroy
      flash[:notice] = "The #{@model_name} was deleted."
    else
      flash[:error] = "The #{@model_name} couldn't be deleted."
    end
    dadmin_done(url(:dadmin, :index, model: @model.to_s))
  end
end
