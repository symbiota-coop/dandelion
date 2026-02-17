Dandelion::App.controller do
  get '/g/:slug/rotas/new' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    @rota = @gathering.rotas.build
    erb :'rotas/build'
  end

  post '/g/:slug/rotas/new' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    @rota = @gathering.rotas.build(mass_assigning(params[:rota], Rota))
    @rota.account = current_account
    if @rota.save
      redirect "/g/#{@gathering.slug}/rotas/#{@rota.id}"
    else
      flash.now[:error] = '<strong>Oops.</strong> Some errors prevented the rota from being saved.'
      erb :'rotas/build'
    end
  end

  get '/g/:slug/rotas' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    redirect "/g/#{@gathering.slug}/rotas/#{@gathering.rotas.first.id}" if @gathering.rotas.count == 1
    erb :'rotas/rotas'
  end

  get '/g/:slug/rotas/:id', provides: [:html, :csv] do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @rota = @gathering.rotas.find(params[:id]) || not_found

    if request.xhr?
      partial :'rotas/rota', locals: { rota: @rota }
    else
      case content_type
      when :html
        erb :'rotas/rota'
      when :csv
        CSV.generate do |csv|
          csv << ([''] + @rota.roles.order('o asc').map(&:name))
          shifts_by_rslot_role = @rota.shifts.includes(:account).index_by { |s| [s.rslot_id, s.role_id] }
          @rota.rslots.order('o asc').each do |rslot|
            row = [rslot.name]
            @rota.roles.order('o asc').each do |role|
              row << if (shift = shifts_by_rslot_role[[rslot.id, role.id]]) && shift.account
                       "#{shift.account.name} #{shift.account.phone}"
                     else
                       ''
                     end
            end
            csv << row
          end
        end
      end
    end
  end

  get '/g/:slug/rotas/:id/edit' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    @rota = @gathering.rotas.find(params[:id]) || not_found
    erb :'rotas/build'
  end

  post '/g/:slug/rotas/:id/edit' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    @rota = @gathering.rotas.find(params[:id]) || not_found
    if @rota.update_attributes(mass_assigning(params[:rota], Rota))
      redirect "/g/#{@gathering.slug}/rotas/#{@rota.id}"
    else
      flash.now[:error] = '<strong>Oops.</strong> Some errors prevented the rota from being saved.'
      erb :'rotas/build'
    end
  end

  get '/g/:slug/rotas/:id/destroy' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    @rota = @gathering.rotas.find(params[:id]) || not_found
    @rota.destroy
    redirect "/g/#{@gathering.slug}/rotas"
  end

  get '/g/:slug/rotas/:id/create_shift' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    @rota = @gathering.rotas.find(params[:id]) || not_found
    erb :'rotas/create_shift'
  end

  post '/g/:slug/rotas/:id/create_shift' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    @rota = @gathering.rotas.find(params[:id]) || not_found
    @rota.shifts.create(mass_assigning(params[:shift], Shift))
    redirect "/g/#{params[:slug]}/rotas/#{params[:id]}"
  end

  post '/roles/order' do
    halt 400 unless params[:rota_id]
    @rota = Rota.find(params[:rota_id]) || not_found
    @gathering = @rota.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    params[:role_ids].each_with_index do |role_id, i|
      @rota.roles.find(role_id).set(o: i)
    end
    200
  end

  post '/roles/create' do
    halt 400 unless params[:rota_id]
    @rota = Rota.find(params[:rota_id]) || not_found
    @gathering = @rota.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    Role.create(name: params[:name], rota: @rota)
    200
  end

  get '/roles/:id/edit' do
    @role = Role.find(params[:id]) || not_found
    @gathering = @role.rota.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    erb :'rotas/role'
  end

  post '/roles/:id/edit' do
    @role = Role.find(params[:id]) || not_found
    @gathering = @role.rota.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    if @role.update_attributes(mass_assigning(params[:role], Role))
      redirect "/g/#{@gathering.slug}/rotas/#{@role.rota_id}"
    else
      flash.now[:error] = '<strong>Oops.</strong> Some errors prevented the slot from being saved.'
      erb :'rotas/role'
    end
  end

  get '/roles/:id/destroy' do
    @role = Role.find(params[:id]) || not_found
    @gathering = @role.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    @role.destroy
    redirect "/g/#{@gathering.slug}/rotas/#{@role.rota_id}"
  end

  post '/rslots/order' do
    halt 400 unless params[:rota_id]
    @rota = Rota.find(params[:rota_id]) || not_found
    @gathering = @rota.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    params[:rslot_ids].each_with_index do |rslot_id, i|
      @rota.rslots.find(rslot_id).set(o: i)
    end
    200
  end

  post '/rslots/create' do
    halt 400 unless params[:rota_id]
    @rota = Rota.find(params[:rota_id]) || not_found
    @gathering = @rota.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    Rslot.create(name: params[:name], rota: @rota)
    200
  end

  get '/rslots/:id/edit' do
    @rslot = Rslot.find(params[:id]) || not_found
    @gathering = @rslot.rota.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    erb :'rotas/rslot'
  end

  post '/rslots/:id/edit' do
    @rslot = Rslot.find(params[:id]) || not_found
    @gathering = @rslot.rota.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    if @rslot.update_attributes(mass_assigning(params[:rslot], Rslot))
      redirect "/g/#{@gathering.slug}/rotas/#{@rslot.rota_id}"
    else
      flash.now[:error] = '<strong>Oops.</strong> Some errors prevented the slot from being saved.'
      erb :'rotas/rslot'
    end
  end

  get '/rslots/:id/destroy' do
    @rslot = Rslot.find(params[:id]) || not_found
    @gathering = @rslot.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    @rslot.destroy
    redirect "/g/#{@gathering.slug}/rotas/#{@rslot.rota_id}"
  end

  get '/rota/rslot/role/:rota_id/:rslot_id/:role_id' do
    @rota = Rota.find(params[:rota_id]) || not_found
    @rslot = Rslot.find(params[:rslot_id]) || not_found
    @role = Role.find(params[:role_id]) || not_found
    @gathering = @rota.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    partial :'rotas/rota_rslot_role', locals: { rota: @rota, rslot: @rslot, role: @role, shift: Shift.includes(:account).find_by(rslot: @rslot, role: @role) }
  end

  get '/shifts/create' do
    halt 400 unless params[:rota_id]
    @rota = Rota.find(params[:rota_id]) || not_found
    @gathering = @rota.gathering
    confirmed_membership_required!
    Shift.create(account: (params[:na] ? nil : current_account), rota_id: params[:rota_id], rslot_id: params[:rslot_id], role_id: params[:role_id])
    200
  end

  get '/shifts/:id/edit' do
    @shift = Shift.find(params[:id]) || not_found
    @gathering = @shift.rota.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    halt unless (@shift.account && (@shift.account_id == current_account.id)) || @membership.admin?
    erb :'rotas/shift'
  end

  post '/shifts/:id/edit' do
    @shift = Shift.find(params[:id]) || not_found
    @gathering = @shift.rota.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    halt unless (@shift.account && (@shift.account_id == current_account.id)) || @membership.admin?
    if @shift.update_attributes(mass_assigning(params[:shift], Shift))
      redirect "/g/#{@gathering.slug}/rotas/#{@shift.rota_id}"
    else
      flash.now[:error] = 'There was an error saving the shift'
      erb :'rotas/shift'
    end
  end

  get '/shifts/:id/destroy' do
    @shift = Shift.find(params[:id]) || not_found
    @gathering = @shift.rota.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    halt unless (@shift.account && (@shift.account_id == current_account.id)) || @membership.admin?
    @shift.destroy
    redirect "/g/#{@gathering.slug}/rotas/#{@shift.rota_id}"
  end
end
