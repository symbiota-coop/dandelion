require_relative 'test_config'
require_relative 'helpers/comments_helpers'

# The unsubscribe links in emails. A GET can be sent with the viewer's session by another site's link or an <img> on any
# page, so each link signs in (its link token) and asks, and only the button, a POST, unsubscribes
class UnsubscribeLinksTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods
  include CommentsHelpers

  def link_with_token(path, account)
    account.set(email_confirmed: true)
    account.generate_link_token!
    "#{path}?link_token=#{account.link_token}"
  end

  # The event's discussion, which @attendee is subscribed to
  def discussion
    create_event(prices: [0])
    @attendee = FactoryBot.create(:account)
    @event.tickets.create!(account: @attendee, ticket_type: @event.ticket_types.first, payment_completed: true)
    @event.discussion_post!(@attendee).subscriptions.create!(account: @attendee)
  end

  def subscribed_to_discussion?
    @event.discussion_post.subscriptions.and(account: @attendee).exists?
  end

  # @teamship of @member in @team, subscribed to @post's emails
  def team_member
    team_thread
    @teamship = @team.teamships.find_by(account: @member) || @team.teamships.create!(account: @member, gathering: @gathering)
    @post.subscriptions.find_or_create_by!(account: @member)
  end

  def follow
    @followee = FactoryBot.create(:account, name: 'Followed Person', has_signed_in: true) # a public profile
    @follower = FactoryBot.create(:account)
    @follow = Follow.create!(follower: @follower, followee: @followee)
  end

  test "the link in older discussion emails asks, and its button unsubscribes" do
    covers_route 'GET /e/:slug/unsubscribe_discussion', 'POST /e/:slug/unsubscribe_discussion'
    discussion
    visit link_with_token("/e/#{@event.slug}/unsubscribe_discussion", @attendee)
    assert page.has_content?("Stop emails about the discussion of #{@event.name}?")
    assert subscribed_to_discussion?
    click_on 'Unsubscribe'
    assert page.has_content?("You unsubscribed from the discussion of #{@event.name}")
    refute subscribed_to_discussion?
  end

  test "a post's unsubscribe link asks, and its button unsubscribes" do
    covers_route 'GET /posts/:id/unsubscribe'
    team_member
    visit link_with_token("/posts/#{@post.id}/unsubscribe", @member)
    assert page.has_content?('Stop emails about replies to this post?')
    assert @post.subscriptions.find_by(account: @member)
    click_on 'Unsubscribe'
    assert page.has_content?('You unsubscribed from the post')
    assert_nil @post.subscriptions.find_by(account: @member)
  end

  test "a gathering's unsubscribe link asks, and its button unsubscribes" do
    covers_route 'GET /g/:slug/unsubscribe'
    team_member
    membership = @gathering.memberships.find_by(account: @member)
    visit link_with_token(gathering_path('/unsubscribe'), @member)
    assert page.has_content?("Stop emails from #{@gathering.name}?")
    assert_equal false, membership.reload.unsubscribed
    click_on 'Unsubscribe'
    assert page.has_current_path?('/accounts/subscriptions')
    assert_equal true, membership.reload.unsubscribed
  end

  test "a team's unsubscribe link asks, and its button unsubscribes" do
    covers_route 'GET /g/:slug/teamships/:id/unsubscribe'
    team_member
    visit link_with_token(gathering_path("/teams/#{@team.id}/unsubscribe"), @member)
    assert page.has_content?("Stop emails about #{@team.name}?")
    assert_equal false, @teamship.reload.unsubscribed
    click_on 'Unsubscribe'
    assert page.has_content?("OK! You won't receive emails about #{@team.name}")
    assert_equal true, @teamship.reload.unsubscribed
    assert_nil @post.subscriptions.find_by(account: @member)
  end

  test "a followed person's unsubscribe link asks, and its button unsubscribes" do
    covers_route 'GET /u/:username/unsubscribe', 'POST /u/:username/unsubscribe'
    follow
    visit link_with_token("/u/#{@followee.username}/unsubscribe", @follower)
    assert page.has_content?('Stop emails about Followed Person?')
    assert_equal false, @follow.reload.unsubscribed
    click_on 'Unsubscribe'
    assert page.has_content?('You were unsubscribed from Followed Person.')
    assert_equal true, @follow.reload.unsubscribed
  end

  # As an <img src> on another page would: signed in already, with no token in the URL
  test 'a GET of an unsubscribe URL changes nothing' do
    discussion
    team_member
    follow
    membership = @gathering.memberships.find_by(account: @member)
    subscription = @post.subscriptions.find_by(account: @member)

    sign_in_with_rack(@attendee)
    get "/e/#{@event.slug}/unsubscribe_discussion"
    assert_equal 200, last_response.status
    assert subscribed_to_discussion?

    sign_in_with_rack(@member)
    [gathering_path('/unsubscribe'), gathering_path("/teamships/#{@teamship.id}/unsubscribe"), "/posts/#{@post.id}/unsubscribe"].each do |path|
      get path
      assert_equal 200, last_response.status, path
    end
    get "/subscriptions/#{subscription.id}/unsubscribe" # only the pagelet's POST, which is all that links to it
    assert_equal 405, last_response.status
    assert_equal false, membership.reload.unsubscribed
    assert_equal false, @teamship.reload.unsubscribed
    assert Subscription.find(subscription.id)

    sign_in_with_rack(@follower)
    get "/u/#{@followee.username}/unsubscribe"
    assert_equal 200, last_response.status
    assert_equal false, @follow.reload.unsubscribed

    # The same unsubscribes, as POSTs, do unsubscribe
    post "/u/#{@followee.username}/unsubscribe"
    assert_equal true, @follow.reload.unsubscribed
    sign_in_with_rack(@member)
    post gathering_path('/unsubscribe')
    assert_equal true, membership.reload.unsubscribed
  end
end
