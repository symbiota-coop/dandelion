require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class MessagesTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  def create_messenger(**attrs)
    account = FactoryBot.create(:account, **attrs)
    account.set(email_confirmed: true, can_message: true)
    account
  end

  def create_messaging_pair
    @account = create_messenger
    @account1 = create_messenger
  end

  def create_message(messenger:, messengee:, body: 'Hello', at: nil)
    message = Message.create!(body: body, messenger: messenger, messengee: messengee)
    message.set(created_at: at) if at
    message.reload
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Sending
  # ═══════════════════════════════════════════════════════════════════════════

  test 'requires a body and an able messenger' do
    create_messaging_pair
    sender = FactoryBot.create(:account)

    blank = Message.new(body: nil, messenger: @account, messengee: @account1)
    refute blank.valid?
    assert blank.errors[:body].any?

    unable = Message.new(body: 'Hi', messenger: sender, messengee: @account1)
    refute unable.valid?
    assert unable.errors[:messenger].any?

    @account.set(blocked_from_messaging: true)
    blocked = Message.new(body: 'Hi', messenger: @account, messengee: @account1)
    refute blocked.valid?
    assert blocked.errors[:messenger].any?
  end

  test 'caps distinct recipients in a rolling window' do
    sender = create_messenger
    recipients = Array.new(Message::MESSENGER_RATE_10_MIN + 1) { create_messenger }
    recipients.take(Message::MESSENGER_RATE_10_MIN).each do |recipient|
      create_message(messenger: sender, messengee: recipient)
    end

    refute Message.new(body: 'Hi', messenger: sender, messengee: recipients.last).valid?
    assert Message.new(body: 'Hi again', messenger: sender, messengee: recipients.first).valid?
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Threads
  # ═══════════════════════════════════════════════════════════════════════════

  test 'between returns both directions and other_party is the counterpart' do
    create_messaging_pair
    outgoing = create_message(messenger: @account, messengee: @account1, body: 'Outgoing')
    incoming = create_message(messenger: @account1, messengee: @account, body: 'Incoming')
    other = create_messenger
    create_message(messenger: @account, messengee: other, body: 'Elsewhere')

    assert_equal [outgoing.id, incoming.id].sort, Message.between(@account, @account1).pluck(:id).sort
    assert_equal @account1.id, outgoing.other_party(@account).id
    assert_equal @account.id, outgoing.other_party(@account1).id
  end

  test 'conversations returns the latest message per person newest first' do
    create_messaging_pair
    account2 = create_messenger
    older = create_message(messenger: @account, messengee: @account1, body: 'Older', at: 2.hours.ago)
    create_message(messenger: @account1, messengee: @account, body: 'Reply', at: 90.minutes.ago)
    latest_with_account1 = create_message(messenger: @account, messengee: @account1, body: 'Latest with 1', at: 1.hour.ago)
    latest_with_account2 = create_message(messenger: @account, messengee: account2, body: 'Latest with 2', at: 30.minutes.ago)

    conversations = @account.conversations
    assert_equal [latest_with_account2.id, latest_with_account1.id], conversations.map(&:id)
    assert_equal [account2.id, @account1.id], (conversations.map { |message| message.other_party(@account).id })
    refute_includes conversations.map(&:id), older.id
    assert_equal [latest_with_account2.id], @account.conversations(limit: 1).map(&:id)
  end

  test 'conversations fills the limit after dropping deleted counterparties' do
    create_messaging_pair
    gone = create_messenger
    account2 = create_messenger
    older = create_message(messenger: @account, messengee: @account1, body: 'Oldest living', at: 3.hours.ago)
    create_message(messenger: @account, messengee: gone, body: 'Deleted person', at: 2.hours.ago)
    newer = create_message(messenger: @account, messengee: account2, body: 'Newest living', at: 1.hour.ago)
    Account.collection.delete_one(_id: gone.id)

    conversations = @account.conversations(limit: 2)
    assert_equal [newer.id, older.id], conversations.map(&:id)
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Read state
  # ═══════════════════════════════════════════════════════════════════════════

  test 'mark_read! only bumps a receipt that is behind the latest inbound message' do
    create_messaging_pair
    create_message(messenger: @account1, messengee: @account, at: 2.hours.ago)

    receipt = MessageReceipt.mark_read!(messenger: @account1, messengee: @account)
    receipt.set(received_at: 1.hour.ago)
    received_at = receipt.reload.received_at
    assert Message.read?(@account1, @account)
    refute Message.unread?(@account1, @account)

    unchanged = MessageReceipt.mark_read!(messenger: @account1, messengee: @account)
    assert_equal received_at, unchanged.reload.received_at

    create_message(messenger: @account1, messengee: @account, at: 30.minutes.ago)
    assert Message.unread?(@account1, @account)

    bumped = MessageReceipt.mark_read!(messenger: @account1, messengee: @account)
    assert bumped.reload.received_at > received_at
    assert Message.read?(@account1, @account)
  end

  test 'unchecked_messages? follows last_checked_messages' do
    create_messaging_pair
    refute @account.unchecked_messages?

    create_message(messenger: @account1, messengee: @account, at: 1.hour.ago)
    assert @account.reload.unchecked_messages?

    @account.set(last_checked_messages: Time.now)
    refute @account.reload.unchecked_messages?
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Controllers
  # ═══════════════════════════════════════════════════════════════════════════

  test 'messages routes require sign in' do
    create_messaging_pair

    get '/messages'
    assert last_response.redirect?

    post "/messages/#{@account1.id}/send", body: 'Hi'
    assert last_response.redirect?
  end

  test 'sending a message and opening the thread marks it read' do
    create_messaging_pair
    sign_in_with_rack(@account)

    post "/messages/#{@account1.id}/send", body: 'Hi there'
    assert_equal 200, last_response.status
    message = Message.between(@account, @account1).first
    assert_equal 'Hi there', message.body

    sign_in_with_rack(@account1)
    get "/messages/#{@account.id}"
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Hi there'
    assert Message.read?(@account, @account1)
  end

  test 'cannot message yourself and empty bodies are rejected' do
    create_messaging_pair
    sign_in_with_rack(@account)

    get "/messages/#{@account.id}"
    assert last_response.redirect?
    assert_equal '/messages', URI(last_response.location).path

    post "/messages/#{@account1.id}/send", body: ''
    assert_equal 400, last_response.status
  end

  test 'index lists conversations and offers more when the page is full' do
    create_messaging_pair
    account2 = create_messenger
    create_message(messenger: @account, messengee: @account1, body: 'With account 1')
    create_message(messenger: @account, messengee: account2, body: 'With account 2')
    sign_in_with_rack(@account)

    get '/messages/index', m: 1
    assert_equal 200, last_response.status
    assert_includes last_response.body, account2.name
    refute_includes last_response.body, @account1.name
    assert_includes last_response.body, 'More'
  end
end
