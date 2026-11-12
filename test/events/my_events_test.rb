require_relative '../test_config'

# My events (/events/my): the events someone has tickets for, hosts or has starred, upcoming and past
class MyEventsTest < ActiveSupport::TestCase
  include Capybara::DSL

  def ticket_for(event, account, payment_completed: true)
    event.tickets.create!(account: account, ticket_type: event.ticket_types.first, price: 10, payment_completed: payment_completed)
  end

  test 'upcoming lists the events someone has a ticket for or helps run, and nobody else’s' do
    create_organisation
    me = FactoryBot.create(:account)
    someone_else = FactoryBot.create(:account)
    attending = create_event(prices: [10], as: :attending, name: 'Attending Gathering')
    ticket_for(attending, me)
    facilitating = create_event(prices: [10], as: :facilitating, name: 'Facilitating Circle')
    facilitating.event_facilitations.create!(account: me)
    create_event(prices: [10], as: :coordinating, name: 'Coordinating Retreat', coordinator: me)
    create_event(prices: [10], as: :organising, name: 'Organising Workshop', organiser: me)
    # The revenue sharer must have connected Stripe to the organisation, which is beside the point here
    create_event(prices: [10], as: :revenue_sharing, name: 'Revenue Sharing Talk').set(revenue_sharer_id: me.id)
    # Not mine: an unpaid ticket, someone else's ticket, and one I've only starred (on its own tab)
    ticket_for(create_event(prices: [10], as: :unpaid, name: 'Unpaid Dance'), me, payment_completed: false)
    ticket_for(create_event(prices: [10], as: :theirs, name: 'Their Concert'), someone_else)
    create_event(prices: [10], as: :starred, name: 'Starred Lecture').event_stars.create!(account: me)

    sign_in(me)
    visit '/events/my'
    %w[Attending\ Gathering Facilitating\ Circle Coordinating\ Retreat Organising\ Workshop Revenue\ Sharing\ Talk].each do |name|
      assert page.has_link?(name), name
    end
    assert page.has_no_content?('Unpaid Dance')
    assert page.has_no_content?('Their Concert')
    assert page.has_no_content?('Starred Lecture')
  end

  test 'starred lists the upcoming events someone has starred, and past the events they went to, with their feedback' do
    create_organisation
    me = FactoryBot.create(:account)
    create_event(prices: [10], as: :starred, name: 'Starred Lecture').event_stars.create!(account: me)
    create_event(prices: [10], as: :starred_by_others, name: 'Others Starred').event_stars.create!(account: FactoryBot.create(:account))
    ticket_for(create_event(prices: [10], as: :upcoming, name: 'Upcoming Gathering'), me)
    past = { start_time: 3.days.ago, end_time: 2.days.ago }
    ticket_for(create_event(prices: [10], as: :went, name: 'Went Without Feedback', **past), me)
    reviewed = create_event(prices: [10], as: :reviewed, name: 'Went And Reviewed', **past)
    ticket_for(reviewed, me)
    reviewed.event_feedbacks.create!(account: me, rating: 4, answers: [['How was it?', 'Lovely evening']])
    ticket_for(create_event(prices: [10], as: :theirs, name: 'Their Past Concert', **past), FactoryBot.create(:account))

    sign_in(me)
    visit '/events/my'
    click_link 'Starred'
    assert page.has_link?('Starred Lecture')
    assert page.has_no_content?('Others Starred')
    assert page.has_no_content?('Upcoming Gathering')

    click_link 'Past'
    assert page.has_link?('Went Without Feedback')
    assert page.has_link?('Went And Reviewed')
    assert page.has_no_content?('Their Past Concert')
    assert page.has_no_content?('Upcoming Gathering')
    within(find_by_id(@went.id.to_s)) { assert page.has_link?('Give feedback', href: "/e/#{@went.slug}/give_feedback") }
    within(find_by_id(@reviewed.id.to_s)) do
      assert page.has_content?('Lovely evening')
      assert page.has_css?('.bi-star-fill', count: 4)
      assert page.has_no_link?('Give feedback')
    end
  end

  test 'signing in is needed to see my events' do
    visit '/events/my'
    assert page.has_current_path?('/accounts/new')
  end
end
