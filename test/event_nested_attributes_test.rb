require 'test_config'

class EventNestedAttributesTest < ActiveSupport::TestCase
  include Capybara::DSL

  setup do
    create_full_event_hierarchy
    @ticket_type = FactoryBot.create(:ticket_type, event: @event)
    @event.reload
  end

  def test_destroying_already_deleted_ticket_type_does_not_raise
    ticket_type_id = @ticket_type.id.to_s
    @ticket_type.destroy

    assert_nothing_raised do
      @event.update_attributes(
        ticket_types_attributes: {
          '0' => {
            'id' => ticket_type_id,
            '_destroy' => '1',
            'name' => 'General admission',
            'quantity' => 10
          }
        }
      )
    end
  end

  def test_updating_already_deleted_ticket_type_does_not_raise
    ticket_type_id = @ticket_type.id.to_s
    @ticket_type.destroy

    assert_nothing_raised do
      @event.update_attributes(
        ticket_types_attributes: {
          '0' => {
            'id' => ticket_type_id,
            'name' => 'General admission',
            'quantity' => 10,
            'order' => 0
          }
        }
      )
    end
  end

  def test_destroying_existing_ticket_type_still_works
    ticket_type_id = @ticket_type.id.to_s

    assert @event.update_attributes(
      ticket_types_attributes: {
        '0' => {
          'id' => ticket_type_id,
          '_destroy' => '1',
          'name' => @ticket_type.name,
          'quantity' => @ticket_type.quantity
        }
      }
    )

    assert_nil TicketType.find(ticket_type_id)
  end
end
