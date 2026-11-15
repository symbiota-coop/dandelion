require_relative '../test_config'
require_relative '../helpers/private_sessions_helpers'

# Vouching for a private session: once each, not for your own, with an optional testimonial shown with your name
class AccountPrivateSessionVouchesTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods
  include PrivateSessionsHelpers

  test 'someone vouches for a session with a testimonial, shown with their name, and counted in the list' do
    covers 'private_sessions/vouch-once-not-own@22c3c5'
    covers_route 'POST /ps/:slug/vouch'
    private_session = create_private_session(practitioner)
    client = FactoryBot.create(:account, name: 'Robin Client', has_signed_in: true)

    sign_in client
    visit private_session.path
    assert page.has_content?('No one has vouched for this service yet')
    assert page.has_css?('#vouches h3', text: 'Vouch for this service')
    within('#vouch-form') do
      fill_in 'Testimonial (optional)', with: "Deeply relaxing.\nWould book again"
      click_button 'Vouch'
    end
    assert page.has_content?('Thanks for vouching.')
    within('#vouches') do
      assert page.has_no_content?('No one has vouched for this service yet')
      assert page.has_link?('Robin Client')
      assert page.has_content?('Deeply relaxing.')
      assert page.has_css?('br')
    end
    assert_equal 1, private_session.reload.vouches_count

    visit '/private_sessions'
    assert page.has_css?('#private-sessions .badge', text: '1')
  end

  test "a session opened in the modal doesn't put the cursor in the testimonial" do
    private_session = create_private_session(practitioner)
    sign_in FactoryBot.create(:account, has_signed_in: true)
    visit '/private_sessions'
    within('#private-sessions') { click_link private_session.title }
    within('#modal') { assert page.has_field?('Testimonial (optional)') }
    assert_not_equal 'vouch-testimonial', page.evaluate_script('document.activeElement.id')
  end

  test 'a voucher changes their testimonial and removes their vouch' do
    covers 'private_sessions/vouch-shown-changed@ed4fb9'
    covers_route 'POST /ps/:slug/unvouch'
    private_session = create_private_session(practitioner)
    client = FactoryBot.create(:account, name: 'Robin Client', has_signed_in: true)
    private_session.private_session_vouches.create!(account: client, testimonial: 'Lovely')
    private_session.private_session_vouches.create!(account: FactoryBot.create(:account, name: 'Later Voucher'), testimonial: 'Newer')

    sign_in client
    visit private_session.path
    # Having vouched, their vouch is first, though older, and has Edit rather than the form to vouch
    assert page.has_content?('Lovely')
    assert_equal ['Robin Client', 'Later Voucher'], page.all('#vouches li > div:last-child > div:first-child a').map(&:text)
    assert page.has_no_field?('Testimonial (optional)')
    assert page.has_no_css?('#vouches h3', text: 'Vouch for this service')
    click_button 'Edit'
    within('#vouch-form') do
      assert page.has_field?('Testimonial (optional)', with: 'Lovely')
      fill_in 'Testimonial (optional)', with: 'Even better the second time'
      click_button 'Save'
    end
    assert page.has_content?('Your testimonial was saved.')
    assert page.has_content?('Even better the second time')
    assert_equal 1, private_session.private_session_vouches.and(account_id: client.id).count

    click_button 'Edit'
    within('#vouch-form') { click_link_and_confirm 'Remove my vouch' }
    assert page.has_content?('Your vouch was removed.')
    assert page.has_no_content?('Even better the second time')
    assert_equal 1, private_session.reload.vouches_count
  end

  test "the person offering a session isn't offered Vouch, and can't vouch for it, nor anyone twice" do
    covers 'private_sessions/vouch-once-not-own@22c3c5'
    owner = practitioner
    private_session = create_private_session(owner)
    sign_in owner
    visit private_session.path
    assert page.has_css?('#vouches h3', text: 'Vouches')
    assert page.has_css?('#vouches .text-body-secondary', text: 'No one has vouched for this service yet')
    assert page.has_no_css?('#vouch-form')
    assert page.has_no_css?('#vouches h3', text: 'Vouch for this service')
    assert page.has_no_link?('Vouch')

    assert_not private_session.private_session_vouches.new(account: owner).valid?
    client = FactoryBot.create(:account)
    private_session.private_session_vouches.create!(account: client)
    assert_not private_session.private_session_vouches.new(account: client).valid?
  end

  test 'the routes refuse a vouch for your own session, give each person one vouch, and remove only your own' do
    owner = practitioner
    private_session = create_private_session(owner)
    other = FactoryBot.create(:account)
    private_session.private_session_vouches.create!(account: other, testimonial: 'Theirs')

    sign_in_with_rack owner
    post "#{private_session.path}/vouch", testimonial: 'Mine is great'
    assert_equal 403, last_response.status

    client = FactoryBot.create(:account)
    sign_in_with_rack client
    2.times { |n| post "#{private_session.path}/vouch", testimonial: "Take #{n}" }
    assert_equal ['Take 1'], private_session.private_session_vouches.and(account_id: client.id).pluck(:testimonial)
    post "#{private_session.path}/unvouch"
    assert_equal [other.id], private_session.private_session_vouches.pluck(:account_id)
    assert_equal 1, private_session.reload.vouches_count

    post "#{private_session.path}/vouch", testimonial: 'x' * (PrivateSessionVouch::TESTIMONIAL_MAX_LENGTH + 1)
    assert_equal [other.id], private_session.private_session_vouches.pluck(:account_id)
  end

  test 'a testimonial shows as the text written, not as HTML or links' do
    private_session = create_private_session(practitioner)
    private_session.private_session_vouches.create!(account: FactoryBot.create(:account, has_signed_in: true),
                                                    testimonial: '<b>Bold claim</b> at https://spam.example.com')
    visit private_session.path
    within('#vouches') do
      assert page.has_content?('<b>Bold claim</b> at https://spam.example.com')
      assert page.has_no_css?('b')
      assert page.has_no_link?('https://spam.example.com')
    end
  end

  test 'signed out, Vouch asks someone to sign in, then brings them back to the vouches' do
    covers_route 'GET /ps/:slug/vouch'
    private_session = create_private_session(practitioner)
    get "#{private_session.path}/vouch"
    assert_redirected_to '/accounts/new'

    sign_in_with_rack FactoryBot.create(:account)
    get "#{private_session.path}/vouch"
    assert_equal "http://example.org#{private_session.path}#vouches", last_response.location
  end
end
