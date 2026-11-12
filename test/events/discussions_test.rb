require_relative '../test_config'

# An event's discussion: who sees it, comments, mentions and subscriptions
class EventDiscussionsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  # An attendee of the event, on its page with the discussion open
  def visit_discussion_as_attendee
    attendee = FactoryBot.create(:account)
    @event.tickets.create!(account: attendee, ticket_type: @event.ticket_types.first, payment_completed: true)
    sign_in(attendee)
    visit "/e/#{@event.slug}"
    click_button 'Discussion'
    assert page.has_link?('Email notifications off')
    attendee
  end

  test 'email notifications for a discussion nobody has written in yet make its post' do
    create_event(prices: [0])
    attendee = visit_discussion_as_attendee
    assert_nil @event.discussion_post

    click_link 'Email notifications off'
    assert page.has_link?('Email notifications on')
    assert @event.discussion_post.subscriptions.and(account: attendee).exists?

    click_link 'Email notifications on'
    assert page.has_link?('Email notifications off')
    assert_not @event.discussion_post.subscriptions.and(account: attendee).exists?
  end

  test 'the unsubscribe link in older discussion emails unsubscribes' do
    create_event(prices: [0])
    attendee = FactoryBot.create(:account)
    @event.tickets.create!(account: attendee, ticket_type: @event.ticket_types.first, payment_completed: true)
    @event.discussion_post!(attendee).subscriptions.create!(account: attendee)

    get "/e/#{@event.slug}", link_token: attendee.link_token
    get "/e/#{@event.slug}/unsubscribe_discussion"
    assert last_response.redirect?
    assert_not @event.discussion_post.subscriptions.and(account: attendee).exists?
  end

  test 'people who are not attendees are not shown the discussion' do
    create_event(prices: [0])
    sign_in(FactoryBot.create(:account))
    visit "/e/#{@event.slug}"
    assert page.has_content?(@event.name)
    assert page.has_no_button?('Discussion')
    assert page.has_no_link?('Email notifications off')
  end

  test 'only people who can see the discussion can subscribe to it' do
    create_event(prices: [0])
    outsider = FactoryBot.create(:account)

    get "/e/#{@event.slug}", link_token: outsider.link_token
    post "/e/#{@event.slug}/subscribe_discussion"
    assert_not last_response.ok?
    assert_nil @event.discussion_post
  end

  test 'a discussion comment needs a body' do
    create_event(prices: [0])
    visit_discussion_as_attendee

    fill_in 'comment_body', with: ' '
    click_button 'Post'
    # The discussion reloads once the comment is sent, with the box empty again
    assert page.has_field?('comment_body', with: '')
    assert_not @event.comments.exists?
    assert_nil @event.discussion_post

    fill_in 'comment_body', with: 'Hello'
    click_button 'Post'
    assert page.has_css?('#chat .comment-body', text: 'Hello')
    assert_equal ['Hello'], @event.comments.pluck(:body)
  end

  test 'a discussion comment cannot be edited to nothing' do
    create_event(prices: [0])
    attendee = FactoryBot.create(:account)
    @event.tickets.create!(account: attendee, ticket_type: @event.ticket_types.first, payment_completed: true)
    comment = @event.discussion_post!(attendee).comments.create!(account: attendee, commentable: @event, body: 'Hello')

    get "/e/#{@event.slug}", link_token: attendee.link_token
    post "/comments/#{comment.id}/edit", body: ''
    assert_equal 400, last_response.status
    assert_equal 'Hello', comment.reload.body
  end

  test 'comment mentions link to profiles and subscribe the people mentioned' do
    create_event(prices: [0])
    mentioned = FactoryBot.create(:account, name: 'Ada Lovelace', username: 'ada.lovelace')
    discussion = @event.discussion_post!(@account)
    comment = discussion.comments.create!(account: @account, commentable: @event,
                                          body: "Thanks @Ada.Lovelace. Write to me@example.com, or ask @nobody_here <b>now</b>. See https://example.com/a?b=1&c=2.")

    assert discussion.subscriptions.and(account: mentioned).exists?
    assert_equal 2, discussion.subscriptions.count
    html = comment.body_html
    assert_includes html, '<a href="/u/ada.lovelace">Ada Lovelace</a>. Write'
    assert_includes html, '<a href="mailto:me@example.com" target="_blank">me@example.com</a>'
    assert_includes html, '@nobody_here &lt;b&gt;now&lt;/b&gt;'
    assert_includes html, '<a href="https://example.com/a?b=1&amp;c=2" target="_blank">https://example.com/a?b=1&amp;c=2</a>.'
    assert_includes comment.body_with_additions, %(<a href="#{ENV['BASE_URI']}/u/ada.lovelace">)

    get "/e/#{@event.slug}", link_token: @account.link_token
    assert_includes last_response.body, '<a href="/u/ada.lovelace">Ada Lovelace</a>'
  end

  test 'a comment mention ending in a dot subscribes only the account it links to' do
    create_event(prices: [0])
    jo = FactoryBot.create(:account, username: 'jo')
    jo_dot = FactoryBot.create(:account, username: 'jo.')
    discussion = @event.discussion_post!(@account)
    comment = discussion.comments.create!(account: @account, commentable: @event, body: 'Over to @jo. today')

    assert discussion.subscriptions.and(account: jo_dot).exists?
    assert_not discussion.subscriptions.and(account: jo).exists?
    assert_includes comment.body_html, '<a href="/u/jo.">'
  end
end
