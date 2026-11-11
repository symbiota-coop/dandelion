Dandelion::App.helpers do
  # The members table's columns (gatherings/members, details), in order: each row's cell partial (membership_row/), its
  # header and th attributes, and a footer: block for what the footer shows under it
  def membership_columns
    @membership_columns ||= begin
      gathering = @gathering
      paid_shown = gathering_admin? || !gathering.hide_paid
      paid_total = lambda do
        "#{m gathering.memberships.pluck(:paid).compact.sum, gathering.currency} (#{m gathering.processed_via_dandelion, gathering.currency} processed via Dandelion)"
      end
      columns = [
        { name: 'name', th: { style: 'width: 1px' } },
        { name: 'following' },
        { name: 'proposed_by' },
        { name: 'accepted_at' },
        ({ name: 'suggested_magic_number' } if gathering.democratic_threshold),
        ({ name: 'tickets' } if gathering.any_events?),
        ({ name: 'choices' } if gathering.enable_contributions),
        ({ name: 'requested_contribution' } if gathering.enable_contributions && paid_shown),
        ({ name: 'paid', footer: paid_total } if gathering.enable_contributions && paid_shown),
        ({ name: 'shifts' } if gathering.rotas_shown?),
        ({ name: 'invitations' } if gathering_admin? || !gathering.hide_invitations),
        ({ name: 'actions', header: '' } if gathering_admin?)
      ]
      columns.compact.map { |column| { header: column[:name].humanize, th: {} }.merge(column) }
    end
  end
end
