# Helpers the gathering test files (test/gatherings) share
module GatheringsHelpers
  # @other_gathering, of @other_account, which @gathering's people don't belong to
  def create_other_gathering
    @other_account = FactoryBot.create(:account)
    @other_gathering = FactoryBot.create(:gathering, account: @other_account)
  end

  def membership_of(account, gathering = @gathering)
    gathering.memberships.find_by(account: account)
  end

  # @timetable in @gathering, with a space, a slot and an activity, @tactivity, in that space and slot if scheduled
  def create_timetable(scheduled: false, **attrs)
    @timetable = @gathering.timetables.create!(name: 'Workshops', account: @account, **attrs)
    @space = @timetable.spaces.create!(name: 'Barn')
    @tslot = @timetable.tslots.create!(name: 'Saturday morning')
    @tactivity = @timetable.tactivities.create!(name: 'Yoga', account: @account, **(scheduled ? { space: @space, tslot: @tslot } : {}))
  end

  # @rota in @gathering, with a role and a slot
  def create_rota
    @rota = @gathering.rotas.create!(name: 'Kitchen', account: @account)
    @role = Role.create!(name: 'Cook', rota: @rota)
    @rslot = Rslot.create!(name: 'Morning', rota: @rota)
  end
end
