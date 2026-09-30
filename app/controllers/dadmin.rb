# A generic admin for every model, at /dadmin
class OperatorNotSupported < StandardError; end

Dandelion::App.controller :dadmin do
  before do
    admins_only!
    if params[:model]
      redirect('/') unless AppModels.all.map(&:to_s).include?(params[:model])
      @model = params[:model].constantize
    end
  end

  get :home, map: '/dadmin' do
    erb :'dadmin/home'
  end

  get :index, map: '/dadmin/index/:model', provides: %i[html json csv] do
    if persisted_field?(@model, :created_at)
      @o = :created_at
      @d = :desc
    end
    if @model.respond_to?(:filter_options)
      @o = @model.filter_options[:o]
      @d = @model.filter_options[:d]
    end
    @id = params[:id] if params[:id]
    @q = params[:q] if params[:q]
    @o = params[:o].to_sym if params[:o]
    @d = params[:d].to_sym if params[:d]
    @resources = @model.all
    @resources = @resources.where(id: @id) if @id

    if @q
      query = []
      admin_fields(@model).each do |fieldname, options|
        if options[:type] === :lookup
          assoc_name = assoc(@model, fieldname).class_name
          assoc_model = assoc_name.constantize
          assoc_fields = admin_fields(assoc_model)
          assoc_fieldname = lookup_method(assoc_model)
          assoc_options = assoc_fields[assoc_fieldname]
          if persisted_field?(assoc_model, assoc_fieldname)
            if DADMIN_MATCHABLE_TYPES[:regex].include?(assoc_options[:type])
              query << { fieldname.to_sym.in => assoc_model.where(assoc_fieldname => /#{Regexp.escape(@q)}/i).pluck(:id) }
            elsif DADMIN_MATCHABLE_TYPES[:number].include?(assoc_options[:type]) && (begin
 Float(@q) && true; rescue StandardError; false; 
            end)
              query << { fieldname.to_sym.in => assoc_model.where(assoc_fieldname => @q).pluck(:id) }
            elsif DADMIN_MATCHABLE_TYPES[:id].include?(assoc_options[:type])
              query << { fieldname.to_sym.in => assoc_model.where(assoc_fieldname => @q).pluck(:id) }
            end
          end
        elsif persisted_field?(@model, fieldname)
          if DADMIN_MATCHABLE_TYPES[:regex].include?(options[:type])
            query << { fieldname => /#{Regexp.escape(@q)}/i }
          elsif DADMIN_MATCHABLE_TYPES[:number].include?(options[:type]) && (begin
 Float(@q) && true; rescue StandardError; false; 
          end)
            query << { fieldname => @q }
          elsif DADMIN_MATCHABLE_TYPES[:id].include?(options[:type])
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
          collection_model = @model
          collection_key = :id
        else
          collection, fieldname = fieldname.split('.')
          collection_assoc = assoc(@model, collection, relationship: :has_many)
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
          if DADMIN_MATCHABLE_TYPES[:regex].include?(options[:type])
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
          elsif DADMIN_MATCHABLE_TYPES[:number].include?(options[:type]) && (begin
 Float(q) && true; rescue StandardError; false; 
          end || q.nil?)
            case b
            when :in
              query << { :id.in => collection_model.where(fieldname => q).pluck(collection_key) }
            when :nin
              query << { :id.nin => collection_model.where(fieldname => q).pluck(collection_key) }
            when :gt, :gte, :lt, :lte
              query << { :id.in => collection_model.where(fieldname.to_sym.send(b) => q).pluck(collection_key) }
            end
          elsif DADMIN_MATCHABLE_TYPES[:id].include?(options[:type])
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
      erb :'dadmin/index'
    when :json
      {
        results: @resources.map do |resource|
                   { id: resource.id.to_s,
                     text: "#{resource.send(lookup_method(resource.class))} (id:#{resource.id})" }
                 end
      }.to_json
    when :csv
      fields = admin_fields(@model).select { |_fieldname, options| options[:index] }
      CSV.generate do |csv|
        csv << fields.keys
        @resources.each do |resource|
          csv << fields.map do |fieldname, options|
            if (options[:type] === :lookup) && resource.send(fieldname)
              assoc_name = assoc(@model, fieldname).class_name
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
    @resource = @model.new
    erb :'dadmin/build'
  end

  post :new, map: '/dadmin/new/:model' do
    @resource = @model.new(params[@model.to_s.underscore.gsub('/', '_')])
    if @resource.save
      flash[:notice] = "<strong>Awesome!</strong> The #{@model.model_name.human.downcase} was created successfully."
      params[:popup] ? refreshParent : redirect(url(:dadmin, :index, model: @model.to_s))
    else
      flash.now[:error] =
        "<strong>Oops.</strong> Some errors prevented the #{@model.model_name.human.downcase} from being saved."
      erb :'dadmin/build'
    end
  end

  get :edit, map: '/dadmin/edit/:model/:id' do
    @resource = @model.find(params[:id])
    erb :'dadmin/build'
  end

  post :edit, map: '/dadmin/edit/:model/:id' do
    @resource = @model.find(params[:id])
    if @resource.update_attributes(params[@model.to_s.underscore.gsub('/', '_')])
      flash[:notice] =
        "<strong>Sweet!</strong> The #{@model.model_name.human.downcase} was updated successfully."
      params[:popup] ? refreshParent : redirect(url(:dadmin, :edit, model: @model.to_s, id: @resource.id))
    else
      flash.now[:error] =
        "<strong>Oops.</strong> Some errors prevented the #{@model.model_name.human.downcase} from being saved."
      erb :'dadmin/build'
    end
  end

  post :destroy, map: '/dadmin/destroy/:model/:id' do
    resource = @model.find(params[:id])
    if resource.destroy
      flash[:notice] = "<strong>Boom!</strong> The #{@model.model_name.human.downcase} was deleted."
    else
      flash[:error] = "<strong>Darn!</strong> The #{@model.model_name.human.downcase} couldn't be deleted."
    end
    params[:popup] ? refreshParent : redirect(url(:dadmin, :index, model: @model.to_s))
  end
end
