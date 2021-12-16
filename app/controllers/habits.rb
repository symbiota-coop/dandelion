Dandelion::App.controller do
  get '/habits' do
    sign_in_required!
    @habit = Habit.new
    @date = params[:date] ? Date.parse(params[:date]) : Date.current
    @dates = ((Date.current - 4)..Date.current).to_a.reverse
    @habits = current_account.habits
    @habits = params[:archived] ? @habits : @habits.and(:archived.ne => true)
    @habits = @habits.and(public: true) if params[:public]
    @habits = @habits.and(:public.ne => true) if params[:private]
    erb :'habits/habits'
  end

  get '/g/:slug/habits' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @dates = ((Date.current - 4)..Date.current).to_a.reverse
    erb :'habits/gathering'
  end

  get '/habits/network' do
    sign_in_required!
    @dates = ((Date.current - 4)..Date.current).to_a.reverse
    partial :'habits/log', locals: { accounts: current_account.network }
  end

  get '/habits/me' do
    sign_in_required!
    @dates = ((Date.current - 4)..Date.current).to_a.reverse
    partial :'habits/me'
  end

  post '/habits/new' do
    sign_in_required!
    @habit = current_account.habits.build(params[:habit])
    if @habit.save
      redirect '/habits'
    else
      flash.now[:error] = 'There was an error saving the habit.'
      erb :'habits/habits'
    end
  end

  get '/habits/:id' do
    sign_in_required!
    @habit = Habit.find(params[:id]) || not_found
    halt unless (current_account && (@habit.account.id == current_account.id)) || @habit.public?
    erb :'habits/habit'
  end

  get '/habits/:id/block' do
    @habit = Habit.find(params[:id]) || not_found
    halt unless (current_account && (@habit.account.id == current_account.id)) || @habit.public?
    @date = params[:date] || Date.current
    partial :'habits/block', locals: { habit: @habit, date: @date }
  end

  get '/habits/:id/edit' do
    sign_in_required!
    @habit = current_account.habits.find(params[:id]) || not_found
    erb :'habits/build'
  end

  post '/habits/:id/edit' do
    sign_in_required!
    @habit = current_account.habits.find(params[:id]) || not_found
    if @habit.update_attributes(mass_assigning(params[:habit], Habit))
      redirect '/habits'
    else
      flash.now[:error] = 'There was an error saving the habit.'
      erb :'habits/build'
    end
  end

  get '/habits/:id/destroy' do
    sign_in_required!
    @habit = current_account.habits.find(params[:id]) || not_found
    @habit.destroy
    redirect '/habits'
  end

  post '/habits/:id/completed' do
    sign_in_required!
    @habit = current_account.habits.find(params[:id]) || not_found
    if (habit_completion = @habit.habit_completions.find_by(date: params[:date]))
      habit_completion.destroy
    else
      @habit.habit_completions.create(date: params[:date], comment: params[:comment])
    end
    request.xhr? ? 200 : redirect(back)
  end

  post '/habits/order' do
    sign_in_required!
    params[:habit_ids].each_with_index do |habit_id, i|
      current_account.habits.find(habit_id).update_attribute(:o, i)
    end
    200
  end

  get '/habit_completions/:id/likes' do
    @habit_completion = HabitCompletion.find(params[:id]) || not_found
    partial :'habits/habit_completion_likes', locals: { habit_completion: @habit_completion }
  end

  get '/habit_completions/:id/like' do
    @habit_completion = HabitCompletion.find(params[:id]) || not_found
    @habit_completion.habit_completion_likes.create account: current_account
    200
  end

  get '/habit_completions/:id/unlike' do
    @habit_completion = HabitCompletion.find(params[:id]) || not_found
    @habit_completion.habit_completion_likes.find_by(account: current_account).try(:destroy)
    200
  end
end
