require_relative '../test_config'

# Discount codes: who may create, edit and delete them (on an organisation, activity, local group or event), what makes
# one valid, which events and ticket types it applies to, and when checkout refuses one
class BookingsDiscountCodesTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  # A quote for a booking of one of the event's first ticket type, as the checkout form asks for it
  def quote_with_code(event, code, account: FactoryBot.create(:account))
    Quote.new(event: event, account: account, quantities: { event.ticket_types.first.id.to_s => '1' }, discount_code: code,
              payment_method: 'stripe').validate!
  end

  def fill_in_discount_code(code:, percentage: nil, fixed: nil, maximum_uses: nil, filter: nil)
    fill_in 'discount_code_code', with: code
    fill_in 'discount_code_maximum_uses', with: maximum_uses if maximum_uses
    fill_in 'discount_code_filter', with: filter if filter
    fill_in 'discount_code_percentage_discount', with: percentage if percentage
    fill_in 'discount_code_fixed_discount_amount', with: fixed if fixed
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Managing codes, as an admin
  # ═══════════════════════════════════════════════════════════════════════════

  test 'an organisation admin creates, edits and deletes an organisation-wide discount code' do
    create_organisation
    sign_in(@account)

    visit "/o/#{@organisation.slug}/discount_codes"
    click_link 'Create a discount code'
    fill_in_discount_code(code: 'summer', percentage: 20, maximum_uses: 5, filter: 'early, standard')
    click_button 'Create discount code'
    assert page.has_content? 'The discount code was saved'
    assert page.has_current_path?("/o/#{@organisation.slug}/discount_codes")

    discount_code = @organisation.discount_codes.first
    assert_equal 1, DiscountCode.count
    assert_equal 'SUMMER', discount_code.code
    assert_equal 20, discount_code.percentage_discount
    assert_nil discount_code.fixed_discount_amount
    assert_equal 5, discount_code.maximum_uses
    assert_equal %w[early standard], discount_code.filters
    assert_equal @account, discount_code.account
    assert page.has_link? 'SUMMER'

    # From a percentage to a fixed amount in euros
    click_link 'SUMMER'
    fill_in 'discount_code_percentage_discount', with: ''
    fill_in 'discount_code_fixed_discount_amount', with: '7.5'
    find('#discount_code_fixed_discount_currency').find("option[value='EUR']").select_option
    click_button 'Update discount code'
    assert page.has_content? 'The discount code was saved'
    discount_code.reload
    assert_nil discount_code.percentage_discount
    assert_equal 7.5, discount_code.fixed_discount_amount
    assert_equal Money.new(750, 'EUR'), discount_code.fixed_discount

    click_link 'SUMMER'
    click_link 'Delete'
    within('.confirm-popover') { click_button 'Delete' }
    assert page.has_link? 'Create a discount code'
    assert page.has_no_link? 'SUMMER'
    assert_equal 0, DiscountCode.count
  end

  test "an event admin creates a code for the event, in the event's currency by default" do
    create_event(currency: 'EUR')
    sign_in(@account)

    visit "/e/#{@event.slug}/discount_codes"
    click_link 'Create a discount code'
    assert_equal 'EUR', find('#discount_code_fixed_discount_currency').value
    fill_in_discount_code(code: 'friends', fixed: 5)
    click_button 'Create discount code'
    assert page.has_content? 'The discount code was saved'
    assert page.has_current_path?("/e/#{@event.slug}/discount_codes")

    discount_code = @event.discount_codes.first
    assert_equal 'FRIENDS', discount_code.code
    assert_equal Money.new(500, 'EUR'), discount_code.fixed_discount
    assert_equal 0, @organisation.discount_codes.count
  end

  test 'activity and local group admins create codes that belong to the activity or local group' do
    create_full_event_hierarchy
    sign_in(@account)

    visit "#{@activity.path}/discount_codes"
    click_link 'Create a discount code'
    fill_in_discount_code(code: 'ACTIVITY', percentage: 10)
    click_button 'Create discount code'
    assert page.has_content? 'The discount code was saved'
    assert_equal ['ACTIVITY'], @activity.discount_codes.pluck(:code)

    visit "#{@local_group.path}/discount_codes"
    click_link 'Create a discount code'
    fill_in_discount_code(code: 'LOCAL', percentage: 15)
    click_button 'Create discount code'
    assert page.has_content? 'The discount code was saved'
    assert_equal ['LOCAL'], @local_group.discount_codes.pluck(:code)
    assert_equal 0, @organisation.discount_codes.count
  end

  test 'a code with both a percentage and a fixed discount is not saved, and the form says why' do
    create_event
    sign_in(@account)

    visit "/discount_codes/new?event_id=#{@event.id}"
    fill_in_discount_code(code: 'BOTH', percentage: 10, fixed: 5)
    click_button 'Create discount code'
    assert page.has_content? 'cannot be present if there is a fixed discount'
    assert_equal 0, DiscountCode.count
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Managing codes, without permission
  # ═══════════════════════════════════════════════════════════════════════════

  test "someone who isn't an admin of the event isn't offered its discount codes" do
    create_event
    sign_in(FactoryBot.create(:account))

    visit "/e/#{@event.slug}"
    assert page.has_content? @event.name
    assert page.has_no_link? 'Discount codes', visible: :all

    visit "/e/#{@event.slug}/discount_codes"
    assert page.has_content? "You don't have access to that page"
    assert page.has_current_path?("/e/#{@event.slug}")
  end

  test "someone who isn't an admin can't create, edit or delete another organisation's codes" do
    create_event
    discount_code = @organisation.discount_codes.create!(code: 'THEIRS', percentage_discount: 10)
    event_code = @event.discount_codes.create!(code: 'EVENT', percentage_discount: 10)
    stranger = FactoryBot.create(:account)
    sign_in_with_rack(stranger)

    get "/discount_codes/new?organisation_id=#{@organisation.id}"
    assert last_response.redirect?
    post '/discount_codes/new', organisation_id: @organisation.id.to_s, discount_code: { code: 'MINE', percentage_discount: '100' }
    assert last_response.redirect?
    post '/discount_codes/new', event_id: @event.id.to_s, discount_code: { code: 'MINE', percentage_discount: '100' }
    assert last_response.redirect?
    assert_nil DiscountCode.find_by(code: 'MINE')

    post "/discount_codes/#{discount_code.id}/edit", organisation_id: @organisation.id.to_s, discount_code: { code: 'THEIRS', percentage_discount: '100' }
    assert last_response.redirect?
    post "/discount_codes/#{event_code.id}/edit", event_id: @event.id.to_s, discount_code: { code: 'EVENT', percentage_discount: '100' }
    assert last_response.redirect?
    assert_equal 10, discount_code.reload.percentage_discount
    assert_equal 10, event_code.reload.percentage_discount

    post "/discount_codes/#{discount_code.id}/destroy", organisation_id: @organisation.id.to_s
    assert last_response.redirect?
    assert DiscountCode.find(discount_code.id)

    # With no organisation, activity, local group or event, there's nothing to be an admin of
    post '/discount_codes/new', discount_code: { code: 'MINE', percentage_discount: '100' }
    assert last_response.redirect?
    assert_nil DiscountCode.find_by(code: 'MINE')
  end

  test "an admin of one organisation can't reach another's codes through their own" do
    create_organisation
    other_organisation = FactoryBot.create(:organisation, account: FactoryBot.create(:account))
    other_code = other_organisation.discount_codes.create!(code: 'OTHER', percentage_discount: 10)
    sign_in_with_rack(@account)

    get "/discount_codes/#{other_code.id}/edit", organisation_id: @organisation.id.to_s
    assert_equal 404, last_response.status
    post "/discount_codes/#{other_code.id}/edit", organisation_id: @organisation.id.to_s, discount_code: { code: 'OTHER', percentage_discount: '100' }
    assert_equal 404, last_response.status
    post "/discount_codes/#{other_code.id}/destroy", organisation_id: @organisation.id.to_s
    assert_equal 404, last_response.status

    other_code.reload
    assert_equal 10, other_code.percentage_discount
    assert_equal other_organisation, other_code.codeable
  end

  test "a forged form can't move a code to another organisation or credit it to someone else" do
    create_organisation
    other_organisation = FactoryBot.create(:organisation, account: (other_account = FactoryBot.create(:account)))
    sign_in_with_rack(@account)
    forged = { codeable_type: 'Organisation', codeable_id: other_organisation.id.to_s, account_id: other_account.id.to_s }

    post '/discount_codes/new', organisation_id: @organisation.id.to_s, discount_code: { code: 'FORGED', percentage_discount: '50' }.merge(forged)
    assert last_response.redirect?
    discount_code = DiscountCode.find_by(code: 'FORGED')
    assert_equal @organisation, discount_code.codeable
    assert_equal @account, discount_code.account

    post "/discount_codes/#{discount_code.id}/edit", organisation_id: @organisation.id.to_s, discount_code: { code: 'FORGED', percentage_discount: '50' }.merge(forged)
    assert last_response.redirect?
    discount_code.reload
    assert_equal @organisation, discount_code.codeable
    assert_equal @account, discount_code.account
    assert_equal 0, other_organisation.discount_codes.count
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # What makes a code valid
  # ═══════════════════════════════════════════════════════════════════════════

  test 'a code takes a percentage from 1 to 100 or a positive fixed amount with a currency, not both or neither' do
    create_event
    valid = lambda do |**attrs|
      discount_code = DiscountCode.new(codeable: @event, code: "CODE#{DiscountCode.count}", **attrs)
      [discount_code.valid?, discount_code.errors.full_messages]
    end

    assert valid.call(percentage_discount: 1).first
    assert valid.call(percentage_discount: 100).first
    assert valid.call(fixed_discount_amount: 0.5, fixed_discount_currency: 'GBP').first

    assert_includes valid.call.last, 'Percentage discount or fixed discount must be present'
    assert_includes valid.call(percentage_discount: 10, fixed_discount_amount: 5, fixed_discount_currency: 'GBP').last,
                    'Percentage discount cannot be present if there is a fixed discount'
    assert_includes valid.call(percentage_discount: 0).last, 'Percentage discount must be positive'
    assert_includes valid.call(percentage_discount: -5).last, 'Percentage discount must be positive'
    assert_includes valid.call(percentage_discount: 101).last, 'Percentage discount must be less or equal to 100%'
    assert_includes valid.call(fixed_discount_amount: 0, fixed_discount_currency: 'GBP').last, 'Fixed discount amount must be positive'
    assert_includes valid.call(fixed_discount_amount: 5).last, 'Fixed discount currency must be present if there is a fixed discount amount'
    assert_includes valid.call(percentage_discount: 10, code: nil).last, "Code can't be blank"
  end

  test 'codes are upper-cased, and unique within what they belong to whatever their case' do
    create_event
    create_event(as: :event2)
    @event.discount_codes.create!(code: 'early bird', percentage_discount: 10)
    assert_equal ['EARLY BIRD'], @event.discount_codes.pluck(:code)

    duplicate = @event.discount_codes.build(code: 'Early Bird', percentage_discount: 20)
    assert !duplicate.valid?
    assert duplicate.errors[:code].any?

    # The same code on another event, or the organisation, is fine
    assert @event2.discount_codes.build(code: 'early bird', percentage_discount: 20).valid?
    assert @organisation.discount_codes.build(code: 'EARLY BIRD', percentage_discount: 20).valid?
  end

  test "a filter limits a code to ticket types whose names contain one of its terms, ignoring case" do
    create_event
    discount_code = @event.discount_codes.create!(code: 'EARLY', percentage_discount: 10, filter: ' Early ,Student')
    assert_equal %w[early student], discount_code.filters
    assert discount_code.applies_to_ticket_type?(TicketType.new(name: 'Early bird'))
    assert discount_code.applies_to_ticket_type?(TicketType.new(name: 'STUDENT concession'))
    assert !discount_code.applies_to_ticket_type?(TicketType.new(name: 'Standard'))

    unfiltered = @event.discount_codes.create!(code: 'ANY', percentage_discount: 10)
    assert_equal [], unfiltered.filters
    assert unfiltered.applies_to_ticket_type?(TicketType.new(name: 'Standard'))
  end

  test "a code is used up once it has as many orders as its maximum uses, not counting the order it's on" do
    create_event
    discount_code = @event.discount_codes.create!(code: 'TWICE', percentage_discount: 10, maximum_uses: 2)
    unlimited = @event.discount_codes.create!(code: 'ALWAYS', percentage_discount: 10)
    first = @event.orders.create!(account: FactoryBot.create(:account), currency: 'GBP', discount_code: discount_code)
    assert !discount_code.exhausted?
    second = @event.orders.create!(account: FactoryBot.create(:account), currency: 'GBP', discount_code: discount_code)
    assert discount_code.exhausted?
    assert !discount_code.exhausted?(excluding: second)
    assert !discount_code.exhausted?(excluding: first)

    # A third order doesn't get the code
    third = @event.orders.create!(account: FactoryBot.create(:account), currency: 'GBP', discount_code: discount_code)
    assert_nil third.discount_code
    assert_nil third.percentage_discount
    # but saving one that has it keeps it
    second.save!
    assert_equal discount_code, second.reload.discount_code

    3.times { @event.orders.create!(account: FactoryBot.create(:account), currency: 'GBP', discount_code: unlimited) }
    assert !unlimited.exhausted?
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Which events a code applies to
  # ═══════════════════════════════════════════════════════════════════════════

  test "a code applies to its event, and to every event of its organisation, activity or local group, but no other's" do
    create_full_event_hierarchy
    event_code = @event.discount_codes.create!(code: 'EVENT', percentage_discount: 10)
    organisation_code = @organisation.discount_codes.create!(code: 'ORG', percentage_discount: 10)
    activity_code = @activity.discount_codes.create!(code: 'ACTIVITY', percentage_discount: 10)
    local_group_code = @local_group.discount_codes.create!(code: 'LOCAL', percentage_discount: 10)
    sibling = FactoryBot.create(:event, organisation: @organisation)
    stranger = FactoryBot.create(:event, organisation: FactoryBot.create(:organisation, account: FactoryBot.create(:account)))

    [event_code, organisation_code, activity_code, local_group_code].each { |code| assert code.applies_to?(@event), "#{code.code} should apply" }
    assert organisation_code.applies_to?(sibling)
    [event_code, activity_code, local_group_code].each { |code| assert !code.applies_to?(sibling), "#{code.code} shouldn't apply to another event" }
    [event_code, organisation_code, activity_code, local_group_code].each { |code| assert !code.applies_to?(stranger) }
  end

  test "an order on another event can't keep a code that doesn't apply to it" do
    create_event
    create_event(as: :event2)
    event_code = @event.discount_codes.create!(code: 'EVENT', percentage_discount: 50)
    order = @event2.orders.create!(account: FactoryBot.create(:account), currency: 'GBP', discount_code: event_code)
    assert_nil order.discount_code
    assert_nil order.percentage_discount
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # At checkout
  # ═══════════════════════════════════════════════════════════════════════════

  test "an organisation's code takes its discount off the organisation's events at checkout, entered in any case" do
    create_event(prices: [20], suggested_donation: 0)
    @organisation.discount_codes.create!(code: 'MEMBERS', percentage_discount: 25)
    quote = quote_with_code(@event, '  members ')
    assert_equal 25, quote.percentage_discount
    assert_in_delta 15, quote.total, 0.001
  end

  test "checkout refuses another organisation's or another event's code rather than charging the full price" do
    create_event(prices: [20], suggested_donation: 0)
    create_event(as: :event2, prices: [20])
    other_organisation = FactoryBot.create(:organisation, account: FactoryBot.create(:account))
    other_organisation.discount_codes.create!(code: 'THEIRS', percentage_discount: 50)
    @event2.discount_codes.create!(code: 'SIBLING', fixed_discount_amount: 5, fixed_discount_currency: 'GBP')

    %w[THEIRS SIBLING].each do |code|
      error = assert_raises(OrderBuilder::DiscountCodeInvalid) { quote_with_code(@event, code) }
      assert_equal "The discount code #{code} is not valid for this event.", error.message
    end
  end
end
