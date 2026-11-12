# Helpers the event permission test files (test/events) share
module EventPermissionsHelpers
  def add_member(org, **attrs)
    account = FactoryBot.create(:account)
    account.organisationships.create!(organisation: org, unsubscribed: false, **attrs)
    account
  end

  def add_event_manager(org)
    add_member(org, event_manager: true)
  end

  # Picks an option in a lookup field, a select2 that searches as you type
  def choose_in_lookup(select_id, search, option = search)
    find("##{select_id} + .select2 .select2-selection").click
    # select2 puts its search and results at the end of the page
    find('.select2-search__field').send_keys(search)
    find('.select2-results__option', text: option).click
  end
end
