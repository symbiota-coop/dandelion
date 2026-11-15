require_relative '../test_config'
require_relative '../helpers/private_sessions_helpers'

# Private sessions: one-to-one and small group sessions someone offers by arrangement, listed under Facilitators, and
# booked however the person offering one says
class AccountPrivateSessionsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods
  include PrivateSessionsHelpers

  test 'a session offered in person needs a location, and an online one keeps none' do
    covers 'private_sessions/in-person-needs-location@236503'
    account = practitioner
    in_person = build_private_session(account, location: nil)
    assert_not in_person.valid?
    assert in_person.errors[:location].any?

    either = build_private_session(account, delivery: 'either', location: nil)
    assert_not either.valid?
    assert either.errors[:location].any?

    online = create_private_session(account, title: 'Guided meditation', delivery: 'online', location: 'Stockholm')
    assert_nil online.reload.location
    assert_nil online.coordinates
  end

  test 'a session is for 1 or more people, and one-to-one when no number is given' do
    covers 'private_sessions/group-size@d1c3dd'
    account = practitioner
    assert_equal 1, create_private_session(account, max_participants: nil).max_participants
    assert create_private_session(account, max_participants: 30).persisted?
    [0, -1, 1.5].each do |max_participants|
      private_session = build_private_session(account, max_participants: max_participants)
      assert_not private_session.valid?
      assert private_session.errors[:max_participants].any?, "#{max_participants} people should be refused"
    end
  end

  test 'length and price are a number or a range, and a session with no price is by donation' do
    covers 'private_sessions/length-and-price@e3eebb'
    account = practitioner
    # Stored as numbers: minutes, and a price or the ends of a sliding scale
    { '60' => [60, nil], '60 – 90' => [60, 90], '60-60' => [60, nil] }.each do |text, stored|
      private_session = create_private_session(account, duration_or_range: text)
      assert_equal stored, [private_session.duration_min, private_session.duration_max], text
    end
    ['an hour', '90-60', '0', '45.5', '60-', '-60', '60-90-120'].each do |text|
      private_session = build_private_session(account, duration_or_range: text)
      assert_not private_session.valid?
      assert private_session.errors[:duration_or_range].any?, text
    end
    { '60' => [60.0, nil, nil], '40-80' => [nil, 40.0, 80.0], '12.50' => [12.5, nil, nil] }.each do |text, stored|
      private_session = create_private_session(account, price_or_range: text)
      assert_equal stored, [private_session.price, private_session.price_min, private_session.price_max], text
    end
    ['£60', '80-40', 'by donation', '40 to 80'].each do |text|
      private_session = build_private_session(account, price_or_range: text)
      assert_not private_session.valid?
      assert private_session.errors[:price_or_range].any?, text
    end

    private_session = create_private_session(account, price_or_range: nil, currency: 'EUR')
    assert private_session.by_donation?
    visit private_session.path
    assert page.has_content?('By donation')
    private_session.update!(price_or_range: '40-80')
    assert_equal '40-80', PrivateSession.find(private_session.id).price_or_range
    visit private_session.path
    assert page.has_content?('€40–€80')
  end

  test 'someone offers a private session from the sidebar, and it is listed and on their profile' do
    covers_route 'GET /private_sessions'
    covers_route 'GET /private_sessions/new'
    covers_route 'POST /private_sessions/new'
    account = practitioner
    sign_in account
    visit '/'
    within('#sidebar') { click_link 'Private sessions' }
    assert page.has_css?('h1', text: 'Private sessions')
    click_link 'Offer a private session'
    fill_in 'Name of the session', with: 'Thai massage'
    find('#private_session_tag_names + .select2').click
    find('.select2-search__field').send_keys('Massage', ',', '#Thai', ',')
    select 'In person', from: 'In person or online'
    fill_in 'Location', with: 'Stockholm'
    fill_in 'Maximum number of people', with: '2'
    fill_in 'Length (minutes)', with: '60 – 90'
    # How to book is rich text, in CKEditor
    assert page.has_css?('#private_session_how_to_book ~ .ck-editor')
    execute_script "document.getElementById('private_session_how_to_book').ckeditorInstance.setData(#{'<p>Email sky@example.com</p>'.to_json})"
    fill_in 'Price', with: '40-80'
    assert page.has_no_select?('Currency')
    click_link 'Change currency'
    select 'EUR', from: 'Currency'
    assert page.has_css?('.money-symbol', text: '€')
    assert page.has_link?('Change currency')
    assert page.has_no_select?('Currency')
    click_button 'Create private session'

    assert page.has_css?('h1', text: 'Thai massage')
    assert page.has_current_path?('/ps/thai-massage')
    assert page.has_content?('Up to 2')
    assert page.has_content?('60–90 min')
    assert page.has_content?('€40–€80')
    private_session = account.private_sessions.find_by(title: 'Thai massage')
    assert_equal [%w[massage thai], 'in_person', 2, '60-90', '40-80', 'EUR'],
                 [private_session.tag_names_cache, private_session.delivery, private_session.max_participants, private_session.duration_or_range, private_session.price_or_range, private_session.currency]
    assert private_session.coordinates

    visit '/private_sessions'
    assert page.has_link?('Thai massage', href: private_session.path)
    visit "/u/#{account.username}"
    assert page.has_css?('#private-sessions')
    assert page.has_link?('Thai massage', href: private_session.path)
  end

  test "a session that isn't listed is off the list and its owner's profile for others, but opens from its link" do
    covers 'private_sessions/unlisted@c3f395'
    covers_route 'GET /ps/:slug'
    account = practitioner
    create_private_session(account, title: 'Listed massage')
    unlisted = create_private_session(account, title: 'Unlisted massage', secret: true)

    sign_in FactoryBot.create(:account)
    visit '/private_sessions'
    assert page.has_link?('Listed massage')
    assert page.has_no_link?('Unlisted massage')
    visit "/u/#{account.username}"
    assert page.has_link?('Listed massage')
    assert page.has_no_link?('Unlisted massage')
    visit unlisted.path
    assert page.has_css?('h1', text: 'Unlisted massage')
    click_link 'Return to private sessions'
    assert page.has_css?('h1', text: 'Private sessions')

    sign_in account
    visit "/u/#{account.username}"
    assert page.has_link?('Listed massage')
    assert page.has_link?('Unlisted massage')
  end

  test 'a session says how to book it, linking its email address and booking link, and offers no messaging' do
    covers 'private_sessions/how-to-book@738200'
    private_session = create_private_session(practitioner, how_to_book: '<p>Email sky@example.com or use <a href="https://sky.example.com/book">my booking page</a></p>' \
                                                                         '<p>More at https://sky.example.com/more<script>alert(1)</script></p>')
    sign_in FactoryBot.create(:account)
    visit private_session.path
    within('#how-to-book') do
      assert page.has_link?('sky@example.com', href: 'mailto:sky@example.com')
      assert page.has_link?('my booking page', href: 'https://sky.example.com/book')
      assert page.has_link?('https://sky.example.com/more', href: 'https://sky.example.com/more')
      assert page.has_no_css?('script', visible: :all)
    end
    assert page.has_no_link?(href: %r{/messages/})
  end

  test "a session without an image shows the wash image-less tiles have, and one with an image shows its own" do
    private_session = create_private_session(practitioner, title: 'Thai massage')
    visit private_session.path
    assert page.has_css?('.row .block-fill.ratio-1x1')
    assert page.has_no_css?("img[alt='Thai massage']")

    private_session.image = File.new('app/assets/images/test-event.jpg')
    private_session.save!
    visit private_session.path
    assert page.has_css?("img[alt='Thai massage']")
    assert page.has_no_css?('.block-fill')
  end

  test 'a session in the list opens in a modal, whose title links to its page, and its owner edits it there' do
    account = practitioner
    private_session = create_private_session(account)
    visit '/private_sessions'
    within('#private-sessions') { click_link 'Deep tissue massage' }
    within('#modal') do
      assert page.has_css?('.modal-title', text: 'Deep tissue massage')
      assert page.has_css?('#how-to-book', text: 'sky@example.com')
      # Two columns, the picture on the right filling its own
      column = find('#private-session-picture')
      assert_in_delta column.evaluate_script('this.clientWidth - parseFloat(getComputedStyle(this).paddingLeft) - parseFloat(getComputedStyle(this).paddingRight)'),
                      column.find('.block-fill').evaluate_script('this.getBoundingClientRect().width'), 1
      assert column.evaluate_script('this.getBoundingClientRect().left > document.querySelector("#how-to-book").getBoundingClientRect().right')
      assert page.has_no_link?('Edit')
    end
    assert page.has_current_path?('/private_sessions')
    within('#modal') { click_link 'Deep tissue massage' }
    assert page.has_current_path?(private_session.path)
    assert page.has_css?('h1', text: 'Deep tissue massage')

    sign_in account
    visit '/private_sessions'
    within('#private-sessions') { click_link 'Deep tissue massage' }
    within('#modal') do
      click_link 'Edit'
      assert page.has_css?('.modal-title', text: 'Edit private session')
      # A failed save shows the form again, with its errors, in the modal
      fill_in 'Length (minutes)', with: 'an hour'
      click_button 'Update private session'
      assert page.has_css?('.invalid-feedback', text: /Length/)
      fill_in 'Length (minutes)', with: '60'
      fill_in 'Name of the session', with: 'Sports massage'
      click_button 'Update private session'
    end
    # Saved, the session's page opens, saying so
    assert page.has_content?('The private session was saved.')
    assert page.has_css?('h1', text: 'Sports massage')
    assert page.has_current_path?(private_session.path)
    assert_equal 'Sports massage', private_session.reload.title
  end

  test "the map shows listed sessions offered in person within its box, with the list's filters, and each opens a popup" do
    account = practitioner
    massage = create_private_session(account)
    create_private_session(account, title: 'Secret massage', secret: true)
    create_private_session(account, title: 'Guided meditation', tag_names: %w[meditation], delivery: 'online', location: nil)
    # Geocoding in tests puts everywhere at Gamla Stan
    box = { west: 18.0, south: 59.3, east: 18.1, north: 59.4 }

    get '/private_sessions.json', box.merge(display: 'map')
    points = JSON.parse(last_response.body)['points']
    assert_equal([massage.id.to_s], points.map { |point| TokenEncryptor.decrypt(point['id']).split(':').last })
    get '/private_sessions.json', box.merge(display: 'map', tag: 'meditation')
    assert_empty JSON.parse(last_response.body)['points']
    get '/private_sessions.json', { west: -0.2, south: 51.4, east: 0.0, north: 51.6, display: 'map' }
    assert_empty JSON.parse(last_response.body)['points']

    get "/points/PrivateSession/#{points.first['id']}"
    assert last_response.ok?
    assert_includes last_response.body, %(href="#{massage.path}")
    assert_includes last_response.body, '<span class="badge text-bg-secondary">1-1</span>'
    assert_includes last_response.body, 'target="_parent" href="/private_sessions?tag=massage"'
    secret = account.private_sessions.find_by(title: 'Secret massage')
    get "/points/PrivateSession/#{TokenEncryptor.encrypt("map:PrivateSession:#{secret.id}")}"
    assert_equal 404, last_response.status
  end

  test 'the list of private sessions switches to a map' do
    create_private_session(practitioner)
    visit '/private_sessions'
    click_link 'Map view'
    # Signed out, the map waits for a click to load (maps/_map.erb)
    assert page.has_css?('#map-container')
    assert page.has_no_css?('#private-sessions')
    assert page.has_field?('display', type: :hidden, with: 'map')
  end

  test "a session's URL fills in from its name as it's typed, can be changed, and is its own" do
    covers 'private_sessions/slug-from-name@7bfebc'
    account = practitioner
    taken = create_private_session(account, title: 'Thai massage', slug: 'thai-massage')
    assert_not build_private_session(account, slug: 'thai-massage').valid?
    assert_not build_private_session(account, slug: 'Thai Massage').valid?

    sign_in account
    visit '/private_sessions/new'
    fill_in 'Name of the session', with: 'Nuad Thai'
    assert page.has_field?('URL', with: 'nuad-thai')

    visit "#{taken.path}/edit"
    fill_in 'URL', with: 'nuad-thai-massage'
    click_button 'Update private session'
    assert page.has_current_path?('/ps/nuad-thai-massage')
    assert page.has_css?('h1', text: 'Thai massage')
  end

  test 'private sessions are searched by name and description, filtered by kind and in person or online, and found near a place' do
    covers 'private_sessions/search-filters@4b44bc'
    account = practitioner
    create_private_session(account, title: 'Deep tissue massage')
    create_private_session(account, title: 'Shiatsu', tag_names: %w[bodywork shiatsu], delivery: 'either', description: '<p>Pressure along the meridians</p>')
    create_private_session(account, title: 'Guided meditation', tag_names: %w[meditation], delivery: 'online', location: nil)
    titles = -> { page.all('#private-sessions h2').map(&:text).sort }

    visit '/private_sessions?q=meridians'
    assert_equal ['Shiatsu'], titles.call
    visit '/private_sessions?tag=meditation'
    assert_equal ['Guided meditation'], titles.call
    visit '/private_sessions?q=shiatsu'
    assert_equal ['Shiatsu'], titles.call
    visit '/private_sessions'
    click_link 'bodywork'
    assert page.has_select?('tag', selected: 'bodywork')
    assert_equal ['Shiatsu'], titles.call
    # Online and In person, either or, as on events: a session offered both ways is under each
    visit '/private_sessions'
    check 'Online'
    assert page.has_current_path?(/online=1/)
    assert_equal ['Guided meditation', 'Shiatsu'], titles.call
    check 'In person'
    assert page.has_current_path?(/in_person=1/)
    assert page.has_unchecked_field?('Online')
    assert_equal ['Deep tissue massage', 'Shiatsu'], titles.call

    # Geocoding in tests puts everywhere at Gamla Stan, so sessions with a location are near it and online ones aren't
    Location.stub(:bounds_for, [[18.0, 59.3], [18.1, 59.4]]) do
      visit '/private_sessions?near=Stockholm&online=1'
      assert_equal ['Deep tissue massage', 'Shiatsu'], titles.call
      # A place to be near is somewhere to meet in person
      assert page.has_checked_field?('In person')
      assert page.has_unchecked_field?('Online')
      # And Online isn't near anywhere, so ticking it empties Near
      check 'Online'
      assert page.has_current_path?(/online=1/)
      assert page.has_field?('near', with: '')
      assert_equal ['Guided meditation', 'Shiatsu'], titles.call
    end
    Location.stub(:bounds_for, [[-0.2, 51.4], [0.0, 51.6]]) do
      visit '/private_sessions?near=London'
      assert page.has_content?('No private sessions found')
    end
  end

  test 'the person offering a session edits and deletes it, and others are not offered to' do
    covers 'private_sessions/only-owner-edits@1e71ef'
    covers_route 'GET /ps/:slug/edit'
    covers_route 'POST /ps/:slug/edit'
    covers_route 'POST /ps/:slug/destroy'
    account = practitioner
    private_session = create_private_session(account)

    sign_in FactoryBot.create(:account)
    visit private_session.path
    assert page.has_css?('#how-to-book', text: 'sky@example.com')
    assert page.has_no_link?('Edit')

    sign_in account
    visit private_session.path
    # Edit opens the form in a modal
    click_link 'Edit'
    within('#modal') do
      assert page.has_css?('.modal-title', text: 'Edit private session')
      fill_in 'Name of the session', with: 'Sports massage'
      check 'Secret'
      find('#private_session_tag_names + .select2 .select2-selection__choice__remove').click
    end
    # Removing a tag opens select2's dropdown, which would take the next click
    find('.select2-search__field').send_keys(:escape)
    within('#modal') { click_button 'Update private session' }
    # Saved from the session's page, the page shows the change
    assert page.has_content?('The private session was saved.')
    assert page.has_css?('h1', text: 'Sports massage')
    assert page.has_css?('.badge', text: 'Secret')
    assert_equal ['Sports massage', true, []], [private_session.reload.title, private_session.secret, private_session.tag_names_cache]

    # The edit page, as on phones
    visit "#{private_session.path}/edit"
    click_link 'Return to Sports massage'
    assert page.has_css?('h1', text: 'Sports massage')
    visit "#{private_session.path}/edit"
    click_link_and_confirm 'Delete'
    assert page.has_content?('The private session was deleted')
    assert_nil PrivateSession.find(private_session.id)
  end

  test "another account can't edit or delete a private session by requesting its routes, while a site admin can" do
    covers 'private_sessions/only-owner-edits@1e71ef'
    private_session = create_private_session(practitioner)

    sign_in_with_rack FactoryBot.create(:account)
    get "#{private_session.path}/edit"
    assert last_response.redirect?
    post "#{private_session.path}/edit", private_session: { title: 'Taken over' }
    assert last_response.redirect?
    post "#{private_session.path}/destroy"
    assert last_response.redirect?
    assert_equal 'Deep tissue massage', private_session.reload.title

    sign_in_with_rack FactoryBot.create(:account, admin: true)
    post "#{private_session.path}/edit", private_session: { title: 'Fixed by an admin' }
    assert_redirected_to private_session.path
    assert_equal 'Fixed by an admin', private_session.reload.title
  end

  test "signed out, someone offering a session is asked to sign in, and a form can't set a session's coordinates" do
    get '/private_sessions/new'
    assert last_response.redirect?
    post '/private_sessions/new', private_session: { title: 'Reiki', tag_names: %w[reiki], delivery: 'online' }
    assert last_response.redirect?
    assert_equal 0, PrivateSession.count

    sign_in_with_rack practitioner
    assert_raises(RuntimeError) do
      post '/private_sessions/new', private_session: { title: 'Reiki', tag_names: %w[reiki], delivery: 'online', coordinates: [0, 0] }
    end
    assert_equal 0, PrivateSession.count
  end
end
