require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class EventDraftsTest < ActiveSupport::TestCase
  include Capybara::DSL

  def draft_event_payload(name: 'Rinpoche weekend', extra: {})
    {
      organisation_id: @organisation.id.to_s,
      name: name,
      ticket_types_attributes: {
        '0' => { name: 'Friday Evening', description: '7-9pm', price_or_range: '30', quantity: '15' }
      },
      ticket_groups_attributes: {
        '0' => { name: 'Non-Residential', capacity: '50' }
      }
    }.merge(extra)
  end

  def create_event_draft(name: 'Rinpoche weekend', extra: {})
    @account.drafts.create!(
      model: 'Event',
      name: name,
      url: "/events/new?organisation_id=#{@organisation.id}",
      json: draft_event_payload(name: name, extra: extra).to_json
    )
  end

  # The page autosaves the form as a draft every 10 seconds, so give it time for one
  def wait_for_draft(&)
    using_wait_time(30) { page.document.synchronize { raise Capybara::ExpectationNotMet, 'draft not saved yet' unless yield } }
  end

  test 'draft save keeps ticket types and updates the same draft' do
    covers 'events/draft-autosave-restores-tickets@38928c'
    create_organisation
    sign_in(@account)
    visit "/events/new?organisation_id=#{@organisation.id}"
    fill_in 'Event title*', with: 'Rinpoche weekend'
    click_link 'Tickets'
    click_link 'Add ticket type'
    fill_in 'event_ticket_types_attributes_0_name', with: 'Friday Evening'
    fill_in 'event_ticket_types_attributes_0_description', with: '7-9pm'
    fill_in 'event_ticket_types_attributes_0_price_or_range', with: '30'
    fill_in 'event_ticket_types_attributes_0_quantity', with: '15'
    click_link 'Add ticket group'
    fill_in 'event_ticket_groups_attributes_0_name', with: 'Non-Residential'
    fill_in 'event_ticket_groups_attributes_0_capacity', with: '50'

    wait_for_draft { @account.drafts.exists? }
    draft = @account.drafts.first
    # The page takes the draft's id from the response, to update the same draft next time
    assert page.has_current_path?(/draft_id=#{draft.id}/)
    json = JSON.parse(draft.json)
    assert_equal 'Friday Evening', json.dig('ticket_types_attributes', '0', 'name')
    assert_equal 'Non-Residential', json.dig('ticket_groups_attributes', '0', 'name')

    fill_in 'event_ticket_types_attributes_0_name', with: 'Saturday Full Day'
    wait_for_draft { JSON.parse(draft.reload.json).dig('ticket_types_attributes', '0', 'name') == 'Saturday Full Day' }
    assert_equal 1, @account.drafts.count
  end

  test 'reloading a draft restores ticket types and groups' do
    covers 'events/draft-autosave-restores-tickets@38928c'
    create_organisation
    draft = create_event_draft
    sign_in(@account)
    visit "/events/new?organisation_id=#{@organisation.id}&draft_id=#{draft.id}"

    assert_equal 'Rinpoche weekend', find('#event_name').value
    click_link 'Tickets'
    assert_equal 'Friday Evening', find('#event_ticket_types_attributes_0_name').value
    assert_equal '7-9pm', find('#event_ticket_types_attributes_0_description').value
    assert_equal '30', find('#event_ticket_types_attributes_0_price_or_range').value
    assert_equal '15', find('#event_ticket_types_attributes_0_quantity').value
    assert_equal 'Non-Residential', find('#event_ticket_groups_attributes_0_name').value
    assert_equal '50', find('#event_ticket_groups_attributes_0_capacity').value

    click_link 'Add ticket type'
    assert page.has_css?('#event_ticket_types_attributes_1_name')
  end

  test 'reloading a draft restores checkboxes' do
    create_organisation
    draft = create_event_draft(extra: { evergreen: '1', secret: '1', ask_hear_about: '0' })
    sign_in(@account)
    visit "/events/new?organisation_id=#{@organisation.id}&draft_id=#{draft.id}"

    assert find('#event_evergreen', visible: :all).checked?
    assert find('#event_secret', visible: :all).checked?
    click_link 'Questions'
    refute find('#event_ask_hear_about', visible: :all).checked?
  end

  test 'adding a ticket type after removing an earlier one uses a new index' do
    create_organisation
    draft = create_event_draft
    sign_in(@account)
    visit "/events/new?organisation_id=#{@organisation.id}&draft_id=#{draft.id}"
    click_link 'Tickets'
    click_link 'Add ticket type'
    fill_in 'event_ticket_types_attributes_1_name', with: 'Saturday Full Day'
    first('#ticket_types .remove-ticket-type').click
    click_link 'Add ticket type'

    assert page.has_css?('#event_ticket_types_attributes_1_name')
    assert page.has_css?('#event_ticket_types_attributes_2_name')
    assert_equal 2, page.all('#ticket_types .ticket_type').count
    assert_equal 'Saturday Full Day', find('#event_ticket_types_attributes_1_name').value
  end

  test 'creating an event from a restored draft keeps ticket types' do
    covers 'events/draft-autosave-restores-tickets@38928c'
    create_organisation
    event = FactoryBot.build_stubbed(:event)
    draft = create_event_draft(name: event.name)
    sign_in(@account)
    visit "/events/new?organisation_id=#{@organisation.id}&draft_id=#{draft.id}"
    execute_script %{$('#event_start_time').val('#{event.start_time.to_fs(:db_local)}')}
    execute_script %{$('#event_end_time').val('#{event.end_time.to_fs(:db_local)}')}
    click_link 'Everything else'
    click_button 'Create event'

    created = Event.find_by(name: event.name)
    assert created, 'Event should be created from the restored draft'
    assert_equal 1, created.ticket_types.count
    ticket_type = created.ticket_types.first
    assert_equal 'Friday Evening', ticket_type.name
    assert_equal '7-9pm', ticket_type.description
    assert_equal 30, ticket_type.price
    assert_equal 15, ticket_type.quantity
    assert_equal 1, created.ticket_groups.count
    assert_equal 'Non-Residential', created.ticket_groups.first.name
  end
end
