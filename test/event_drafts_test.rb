require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class EventDraftsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

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

  test 'draft save keeps ticket types and updates the same draft' do
    create_organisation
    sign_in_with_rack(@account)

    post '/events/draft', {
      event: draft_event_payload
    }, { 'HTTP_REFERER' => "http://example.org/events/new?organisation_id=#{@organisation.id}" }

    assert_equal 200, last_response.status, last_response.body
    first = JSON.parse(last_response.body)
    draft = @account.drafts.find(first['draft_id'])
    assert draft
    json = JSON.parse(draft.json)
    assert_equal 'Friday Evening', json.dig('ticket_types_attributes', '0', 'name')
    assert_equal 'Non-Residential', json.dig('ticket_groups_attributes', '0', 'name')

    post '/events/draft', {
      draft_id: first['draft_id'],
      event: draft_event_payload.merge(
        ticket_types_attributes: {
          '0' => { name: 'Saturday Full Day', description: '10am-4.30pm', price_or_range: '75', quantity: '5' }
        }
      )
    }, { 'HTTP_REFERER' => "http://example.org/events/new?organisation_id=#{@organisation.id}&draft_id=#{first['draft_id']}" }

    assert_equal 200, last_response.status, last_response.body
    second = JSON.parse(last_response.body)
    assert_equal first['draft_id'], second['draft_id']
    assert_equal 1, @account.drafts.count
    json = JSON.parse(@account.drafts.find(second['draft_id']).json)
    assert_equal 'Saturday Full Day', json.dig('ticket_types_attributes', '0', 'name')
  end

  test 'reloading a draft restores ticket types and groups' do
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

  test 'creating an event from a restored draft keeps ticket types' do
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
