module MembershipRows
  extend ActiveSupport::Concern

  class_methods do
    # Loads a page of a gathering's members table (gatherings/_membership_row) with a query per collection, rather than
    # a dozen queries per row: each membership is handed its tickets, shifts, invitations, proposers and the viewer's
    # follow of its account, so the methods below read those. A membership loaded on its own (a row reloaded by
    # /membership_row/:id) queries for them itself
    def preload_rows(gathering, memberships, viewer:)
      memberships = memberships.includes(:account, :added_by, :mapplication, teamships: :team, optionships: :option).to_a
      account_ids = memberships.map(&:account_id)
      mapplication_ids = memberships.filter_map(&:mapplication_id)

      tickets = gathering.any_events? ? event_tickets_by_account(gathering, account_ids) : {}
      shifts = gathering.rotas_shown? ? Shift.and(:membership_id.in => memberships.map(&:id)).includes(:rota, :role, :rslot).group_by(&:membership_id) : {}
      invitations_extended = gathering.memberships.and(:added_by_id.in => account_ids).pluck(:added_by_id).tally
      verdicts = Verdict.and(:mapplication_id.in => mapplication_ids).includes(:account).group_by(&:mapplication_id)
      follows = viewer ? viewer.follows_as_follower.and(:followee_id.in => account_ids).index_by(&:followee_id) : {}

      memberships.each do |membership|
        membership.assign_preloaded_row(
          event_tickets: tickets.fetch(membership.account_id, []),
          shifts: shifts.fetch(membership.id, []),
          invitations_extended: invitations_extended.fetch(membership.account_id, 0),
          verdicts: verdicts.fetch(membership.mapplication_id, []),
          viewer_follow: follows.fetch(membership.account_id, false)
        )
      end
    end

    # Each account's complete tickets to the gathering's events, with their events, in the order of the events
    def event_tickets_by_account(gathering, account_ids)
      events = gathering.events.to_a
      event_order = events.each_with_index.to_h { |event, i| [event.id, i] }
      events_by_id = events.index_by(&:id)
      Ticket.complete.and(:event_id.in => events_by_id.keys, :account_id.in => account_ids).includes(:ticket_type).to_a
            .each_with_index.sort_by { |ticket, i| [event_order[ticket.event_id], i] }
            .group_by { |ticket, _i| ticket.account_id }
            .transform_values { |pairs| pairs.map { |ticket, _i| [events_by_id[ticket.event_id], ticket] } }
    end
  end

  def assign_preloaded_row(event_tickets:, shifts:, invitations_extended:, verdicts:, viewer_follow:)
    @preloaded_event_tickets = event_tickets
    @preloaded_shifts = shifts
    @preloaded_invitations_extended = invitations_extended
    @preloaded_verdicts = verdicts
    @viewer_follow = viewer_follow
  end

  # The viewer's follow of the account, or false if they don't follow it, when preload_rows has looked (nil otherwise)
  attr_reader :viewer_follow

  # The account's complete tickets to the gathering's events, each with its event, in the order of the events
  def event_tickets
    @preloaded_event_tickets || gathering.events.flat_map { |event| event.tickets.complete.and(account: account).map { |ticket| [event, ticket] } }
  end

  def shifts_list
    @preloaded_shifts || shifts.to_a
  end

  def shift_points
    shifts_list.sum(&:worth)
  end

  def invitations_extended
    @preloaded_invitations_extended || gathering.memberships.and(added_by: account).count
  end

  def proposed_by
    if mapplication
      verdicts_list.select { |verdict| verdict.type == 'proposer' }.map(&:account)
    elsif added_by
      [added_by]
    end
  end

  # The proposers and supporters who accepted the membership's application
  def vouchers_count
    verdicts_list.count { |verdict| Verdict.types.include?(verdict.type) }
  end

  private

  def verdicts_list
    return [] unless mapplication

    @preloaded_verdicts || mapplication.verdicts.includes(:account).to_a
  end
end
