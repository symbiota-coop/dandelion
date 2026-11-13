require_relative '../test_config'

# The routes around a discussion's comments that change things: deleting a comment or its file, subscribing to and
# unsubscribing from a thread, adding and deleting photos (on gatherings, comments and ticket types), deleting an
# organisation's mail attachments, and clearing cached fragments. Who may, with others' ids forged in
class MessagesCommentRoutesTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  # A thread in @gathering's General team, opened by @member with @comment
  def team_thread
    create_gathering
    @team = @gathering.teams.find_by(name: 'General')
    @member = create_member
    @post = @team.posts.create!(account: @member, subject: 'Rota')
    @comment = @post.comments.create!(account: @member, body: 'Secret plans')
  end

  # A request as the page's pagelets make it, which a refusal answers with 403 rather than a redirect
  def xhr(method, path, params = {})
    send(method, path, params, 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest')
  end

  def text_file(name = 'notes.txt')
    file = Tempfile.new(['upload', File.extname(name)])
    file.write('Hello')
    file.close
    Rack::Test::UploadedFile.new(file.path, 'text/plain', original_filename: name)
  end

  def image_upload(name = 'coop.png', type = 'image/png')
    Rack::Test::UploadedFile.new("app/assets/images/#{name}", type)
  end

  def svg_upload
    file = Tempfile.new(['upload', '.svg'])
    file.write('<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>')
    file.close
    Rack::Test::UploadedFile.new(file.path, 'image/svg+xml', original_filename: 'picture.svg')
  end

  def without_imagemagick(&)
    Dragonfly.app.shell.stub(:run, ->(command, *) { flunk "ran #{command}" }, &)
  end

  def site_admin
    FactoryBot.create(:account, admin: true)
  end

  # Deleting comments

  test "a comment's author deletes a reply, and deleting the comment that opened a thread deletes the thread" do
    covers_route 'POST /comments/:id/destroy'
    team_thread
    reply = @post.comments.create!(account: @member, body: 'And another thing')
    sign_in_with_rack(@member)

    xhr :post, "/comments/#{reply.id}/destroy"
    assert last_response.ok?
    assert_nil Comment.find(reply.id)
    assert Post.find(@post.id)

    xhr :post, "/comments/#{@comment.id}/destroy"
    assert last_response.ok?
    assert_nil Comment.find(@comment.id)
    assert_nil Post.find(@post.id)
  end

  test "no one but a comment's author deletes it: not another member, the gathering's admin or an outsider" do
    team_thread
    reply = @post.comments.create!(account: @member, body: 'And another thing')

    [create_member(name: 'Other Member'), @account, FactoryBot.create(:account)].each do |account|
      sign_in_with_rack(account)
      xhr :post, "/comments/#{reply.id}/destroy"
      assert_equal 403, last_response.status
      xhr :post, "/comments/#{@comment.id}/destroy"
      assert_equal 403, last_response.status
    end

    assert Comment.find(reply.id)
    assert Comment.find(@comment.id)
    assert Post.find(@post.id)
  end

  test "a comment's author who has left the discussion can't delete it" do
    team_thread
    @gathering.memberships.find_by(account: @member).destroy
    sign_in_with_rack(@member)

    xhr :post, "/comments/#{@comment.id}/destroy"
    assert_equal 403, last_response.status
    assert Comment.find(@comment.id)
  end

  test 'signed out, deleting a comment sends you to sign up' do
    team_thread

    post "/comments/#{@comment.id}/destroy"
    assert last_response.redirect?
    assert_includes last_response.location, '/accounts/new'
    assert Comment.find(@comment.id)
  end

  # Deleting a comment's file

  test "only a comment's author removes its file, while they can still see the discussion" do
    covers_route 'POST /comments/:id/file/destroy'
    team_thread
    @comment.update!(file: text_file)
    assert @comment.reload.file_uid

    [create_member(name: 'Other Member'), @account, FactoryBot.create(:account)].each do |account|
      sign_in_with_rack(account)
      post "/comments/#{@comment.id}/file/destroy"
      assert_equal 403, last_response.status
      assert @comment.reload.file_uid
    end

    sign_in_with_rack(@member)
    post "/comments/#{@comment.id}/file/destroy"
    assert last_response.redirect?
    assert_nil @comment.reload.file_uid
    assert Comment.find(@comment.id)
  end

  test "a comment's author who has left the discussion can't remove its file" do
    team_thread
    @comment.update!(file: text_file)
    @gathering.memberships.find_by(account: @member).destroy
    sign_in_with_rack(@member)

    xhr :post, "/comments/#{@comment.id}/file/destroy"
    assert_equal 403, last_response.status
    assert @comment.reload.file_uid
  end

  # Subscribing and unsubscribing

  test "a discussion's members subscribe to its threads, once each" do
    covers_route 'POST /subscriptions/create'
    team_thread
    other_member = create_member(name: 'Other Member')
    @post.subscriptions.find_by(account: other_member)&.destroy
    sign_in_with_rack(other_member)

    2.times do
      xhr :post, '/subscriptions/create', post_id: @post.id
      assert last_response.ok?
    end
    assert_equal 1, @post.subscriptions.and(account: other_member).count
  end

  test "outsiders can't subscribe to a thread in a discussion they can't see" do
    team_thread
    outsider = FactoryBot.create(:account)
    sign_in_with_rack(outsider)

    xhr :post, '/subscriptions/create', post_id: @post.id
    assert_equal 403, last_response.status
    assert_nil @post.subscriptions.find_by(account: outsider)

    # Nor a member who has left
    @gathering.memberships.find_by(account: @member).destroy
    @post.subscriptions.and(account: @member).destroy_all
    sign_in_with_rack(@member)
    xhr :post, '/subscriptions/create', post_id: @post.id
    assert_equal 403, last_response.status
    assert_nil @post.subscriptions.find_by(account: @member)
  end

  test "unsubscribing from a thread removes only one's own subscription" do
    covers_route 'GET /posts/:id/unsubscribe'
    team_thread
    other_member = create_member(name: 'Other Member')
    @post.subscriptions.find_or_create_by!(account: other_member)
    assert @post.subscriptions.find_by(account: @member)
    sign_in_with_rack(@member)

    get "/posts/#{@post.id}/unsubscribe"
    assert last_response.redirect?
    assert_equal @post.url, last_response.location
    assert_nil @post.subscriptions.find_by(account: @member)
    assert @post.subscriptions.find_by(account: other_member)

    # Someone with no subscription to the thread removes nothing
    sign_in_with_rack(FactoryBot.create(:account))
    get "/posts/#{@post.id}/unsubscribe"
    assert last_response.redirect?
    assert @post.subscriptions.find_by(account: other_member)
  end

  test 'signed out, unsubscribing from a thread sends you to sign up and removes nothing' do
    team_thread
    count = @post.subscriptions.count

    get "/posts/#{@post.id}/unsubscribe"
    assert last_response.redirect?
    assert_includes last_response.location, '/accounts/new'
    assert_equal count, @post.subscriptions.count
  end

  # Photos

  test "a gathering's admins add photos to it, and its other members and outsiders can't" do
    covers_route 'POST /photos/new'
    create_gathering
    member = create_member

    [member, FactoryBot.create(:account)].each do |account|
      sign_in_with_rack(account)
      post '/photos/new', photoable_type: 'Gathering', photoable_id: @gathering.id, image: image_upload
      assert_equal 403, last_response.status
    end
    assert_equal 0, @gathering.photos.count

    sign_in_with_rack(@account)
    post '/photos/new', photoable_type: 'Gathering', photoable_id: @gathering.id, image: image_upload
    photo = @gathering.photos.first
    assert photo
    assert_equal @account.id, photo.account_id
    assert_equal 'jpeg', photo.image.format
    assert_equal photo.url, last_response.location
  end

  test "a comment's author adds photos to it, and no one else can" do
    team_thread

    [create_member(name: 'Other Member'), @account].each do |account|
      sign_in_with_rack(account)
      post '/photos/new', photoable_type: 'Comment', photoable_id: @comment.id, image: image_upload
      assert_equal 403, last_response.status
    end
    assert_equal 0, @comment.photos.count

    sign_in_with_rack(@member)
    post '/photos/new', photoable_type: 'Comment', photoable_id: @comment.id, image: image_upload
    assert last_response.redirect?
    assert_equal 1, @comment.photos.count
  end

  test "a comment's author who has left the discussion can't add photos to it" do
    team_thread
    @gathering.memberships.find_by(account: @member).destroy
    sign_in_with_rack(@member)

    post '/photos/new', photoable_type: 'Comment', photoable_id: @comment.id, image: image_upload
    assert_equal 403, last_response.status
    assert_equal 0, @comment.photos.count
  end

  test "an event's admins add photos to its ticket types, and its attendees can't" do
    create_event(prices: [0])
    ticket_type = @event.ticket_types.first
    attendee = FactoryBot.create(:account)
    @event.tickets.create!(account: attendee, ticket_type: ticket_type, payment_completed: true)

    sign_in_with_rack(attendee)
    post '/photos/new', photoable_type: 'TicketType', photoable_id: ticket_type.id, image: image_upload
    assert_equal 403, last_response.status
    assert_equal 0, ticket_type.photos.count

    sign_in_with_rack(@account)
    post '/photos/new', photoable_type: 'TicketType', photoable_id: ticket_type.id, image: image_upload
    assert_equal "#{ENV.fetch('BASE_URI', nil)}/e/#{@event.slug}/ticket_types", last_response.location
    assert_equal 1, ticket_type.photos.count
  end

  test 'photos go only on gatherings, comments and ticket types, and need signing in' do
    create_gathering
    post '/photos/new', photoable_type: 'Gathering', photoable_id: @gathering.id, image: image_upload
    assert last_response.redirect?
    assert_includes last_response.location, '/accounts/new'

    # Anything else, even an account (which a constantize would find), is refused before it's looked up
    sign_in_with_rack(@account)
    %w[Account Organisation Event Kernel].each do |type|
      post '/photos/new', photoable_type: type, photoable_id: @account.id, image: image_upload
      assert_equal 403, last_response.status
    end
    assert_equal 0, Photo.count
  end

  test "a photo that isn't a JPEG, PNG, GIF, WebP or HEIC is refused before ImageMagick sees it, saying why" do
    create_gathering
    sign_in_with_rack(@account)

    without_imagemagick do
      post '/photos/new', photoable_type: 'Gathering', photoable_id: @gathering.id, image: svg_upload
    end
    # Back to the gathering rather than an error page
    assert_equal "#{ENV.fetch('BASE_URI', nil)}/g/#{@gathering.slug}", last_response.location.split('#').first
    follow_redirect!
    assert_includes last_response.body, 'must be a JPEG, PNG, GIF, WebP or HEIC image'
    assert_equal 0, @gathering.photos.count

    # Or no file at all
    post '/photos/new', photoable_type: 'Gathering', photoable_id: @gathering.id
    assert last_response.redirect?
    assert_equal 0, @gathering.photos.count
  end

  test "a photo's link takes you to the page it's on, not to the image" do
    covers_route 'GET /photos/:id'
    team_thread
    gathering_photo = @gathering.photos.create!(account: @account, image: File.new('app/assets/images/coop.png'))
    comment_photo = @comment.photos.create!(account: @member, image: File.new('app/assets/images/coop.png'))

    get "/photos/#{gathering_photo.id}"
    assert_equal "#{ENV.fetch('BASE_URI', nil)}/g/#{@gathering.slug}#photo-#{gathering_photo.id}", last_response.location

    # A comment's photo goes to its thread, whose page lets in only the discussion's members
    get "/photos/#{comment_photo.id}"
    assert_equal @post.url, last_response.location
    refute_includes last_response.location, comment_photo.image_uid

    get "/photos/#{BSON::ObjectId.new}"
    assert_equal 404, last_response.status
  end

  test "a photo is deleted by whoever added it or a site admin, and no one else" do
    covers_route 'POST /photos/:id/destroy'
    team_thread
    photo = @comment.photos.create!(account: @member, image: File.new('app/assets/images/coop.png'))
    other_photo = @comment.photos.create!(account: @member, image: File.new('app/assets/images/coop.png'))

    post "/photos/#{photo.id}/destroy"
    assert_includes last_response.location, '/accounts/new'

    [create_member(name: 'Other Member'), @account, FactoryBot.create(:account)].each do |account|
      sign_in_with_rack(account)
      post "/photos/#{photo.id}/destroy"
      assert_equal 403, last_response.status
    end
    assert Photo.find(photo.id)

    sign_in_with_rack(@member)
    post "/photos/#{photo.id}/destroy"
    assert_equal @post.url, last_response.location
    assert_nil Photo.find(photo.id)

    sign_in_with_rack(site_admin)
    post "/photos/#{other_photo.id}/destroy"
    assert last_response.redirect?
    assert_nil Photo.find(other_photo.id)
  end

  # An organisation's mail attachments

  test "an organisation's admins delete its mail attachments, and no one else can" do
    covers_route 'POST /pmails/:oid/attachments/:attachment_id/destroy'
    create_organisation
    attachment = @organisation.attachments.create!(file: text_file('flyer.txt'))
    path = "/pmails/#{@organisation.id}/attachments/#{attachment.id}/destroy"

    post path, organisation_id: @organisation.id
    assert last_response.redirect?
    assert Attachment.find(attachment.id)

    # An admin of another organisation, and a follower
    other_admin = FactoryBot.create(:account)
    FactoryBot.create(:organisation, account: other_admin)
    follower = FactoryBot.create(:account)
    @organisation.organisationships.create!(account: follower)
    [other_admin, follower].each do |account|
      sign_in_with_rack(account)
      post path, organisation_id: @organisation.id
      assert last_response.redirect?
      assert Attachment.find(attachment.id)
    end

    sign_in_with_rack(@account)
    post path, organisation_id: @organisation.id
    assert last_response.ok?
    assert_nil Attachment.find(attachment.id)
  end

  test "an organisation's admins can't delete another organisation's mail attachments" do
    create_organisation
    other_organisation = FactoryBot.create(:organisation, account: FactoryBot.create(:account))
    other_attachment = other_organisation.attachments.create!(file: text_file('theirs.txt'))
    sign_in_with_rack(@account)

    # Naming the other organisation in the path, with their own in the scope
    post "/pmails/#{other_organisation.id}/attachments/#{other_attachment.id}/destroy", organisation_id: @organisation.id
    assert_equal 403, last_response.status
    # Their own organisation in the path, with the other's attachment
    post "/pmails/#{@organisation.id}/attachments/#{other_attachment.id}/destroy", organisation_id: @organisation.id
    assert last_response.ok?
    # Or the other organisation as the scope
    post "/pmails/#{other_organisation.id}/attachments/#{other_attachment.id}/destroy", organisation_id: other_organisation.id
    assert last_response.redirect?

    assert Attachment.find(other_attachment.id)
  end

  # Cached fragments

  test "site admins clear cached fragments whose keys match, and others can't clear any" do
    covers_route 'GET /fragments/delete/:q'
    keys = ['homepage/events', 'HOMEPAGE/stats', 'sidebar', 'home.page']
    keys.each { |key| Fragment.create!(key: key, value: 'cached', expires: 1.hour.from_now) }
    # Pages the requests render cache fragments of their own
    left = -> { Fragment.and(:key.in => keys).pluck(:key).sort }

    get '/fragments/delete/homepage'
    assert last_response.redirect?
    assert_equal keys.sort, left.call

    sign_in_with_rack(FactoryBot.create(:account))
    get '/fragments/delete/homepage'
    assert last_response.redirect?
    assert_equal keys.sort, left.call

    sign_in_with_rack(site_admin)
    get '/fragments/delete/homepage'
    assert last_response.redirect?
    assert_equal ['home.page', 'sidebar'], left.call

    # The text is matched as it is, not as a pattern
    get '/fragments/delete/home.page'
    assert_equal ['sidebar'], left.call
  end
end
