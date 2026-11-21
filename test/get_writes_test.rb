require_relative 'test_config'

# The check that a GET or HEAD doesn't change the database (test/setup/get_writes.rb), which runs in every test
class GetWritesTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  # A request through the middleware alone, to a Rack app that runs the block
  def request_through_middleware(method = 'GET', &block)
    GetWrites::Middleware.new(->(_env) { block.call; [200, {}, []] }).call(Rack::MockRequest.env_for('/somewhere', method: method))
  end

  # check_get_writes's failure, if it fails, and the writes forgotten so the test's own teardown passes
  def get_writes_failure
    check_get_writes
    nil
  rescue Minitest::Assertion => e
    e.message
  ensure
    GetWrites.start(self)
  end

  test 'a GET route that writes outside the allowlist fails the test, naming the route, the collection and what to do' do
    PageView.stub(:create, ->(**) { Stash.create!(key: 'written by a GET', value: 'x') }) { get '/' }
    assert Stash.find_by(key: 'written by a GET'), 'the stub was reached'
    message = get_writes_failure
    assert_includes message, 'GET /: insert stashes'
    assert_includes message, 'Make the route a POST'
    assert_includes message, 'GetWrites::ALLOWED'
  end

  test 'a HEAD counts as its GET, and a POST may write' do
    request_through_middleware('HEAD') { Stash.create!(key: 'by a HEAD', value: 'x') }
    assert_includes GetWrites.disallowed.map(&:to_s), 'HEAD /somewhere (no route): insert stashes'
    GetWrites.start(self)

    request_through_middleware('POST') { Stash.create!(key: 'by a POST', value: 'x') }
    assert_nil get_writes_failure
  end

  test 'updates, deletes and $merge aggregates count as writes' do
    stash = Stash.create!(key: 'kept', value: 'x')
    request_through_middleware do
      stash.set(value: 'changed')
      Stash.and(key: 'kept').delete_all
      Stash.collection.aggregate([{ '$match' => {} }, { '$merge' => { 'into' => 'stashes_copy' } }]).to_a
    end
    assert_equal ['GET /somewhere (no route): update stashes (value)', 'GET /somewhere (no route): delete stashes',
                  'GET /somewhere (no route): aggregate stashes'], GetWrites.disallowed.map(&:to_s)
    GetWrites.start(self)
    Mongoid.default_client[:stashes_copy].drop
  end

  test 'an allowlisted write passes, but only with the fields its entry names' do
    account = FactoryBot.create(:account)
    request_through_middleware { account.set(last_active: Time.now) }
    assert_equal ['accounts'], GetWrites.writes.map(&:collection), 'the write was recorded'
    assert_nil get_writes_failure

    request_through_middleware { account.set(last_active: Time.now, admin: true) }
    assert_includes get_writes_failure, 'update accounts (last_active, admin)'
  end

  test 'a sign in write is allowed only when the request has a link token or sign in code' do
    account = FactoryBot.create(:account)
    app = GetWrites::Middleware.new(->(_env) { account.set(sign_ins_count: 1); [200, {}, []] })
    app.call(Rack::MockRequest.env_for('/?link_token=abc'))
    assert_nil get_writes_failure
    app.call(Rack::MockRequest.env_for('/'))
    assert_includes get_writes_failure, 'update accounts (sign_ins_count)'
  end

  # Browser tests run the app on Capybara's server threads while the test thread talks to Mongo too
  test "the test thread's writes during a GET on another thread aren't the GET's, and the GET's own are" do
    started = Queue.new
    finish = Queue.new
    request = Thread.new do
      request_through_middleware do
        started << true
        finish.pop
        Stash.create!(key: 'by the request', value: 'x')
      end
    end
    started.pop
    Stash.create!(key: 'by the test thread', value: 'x')
    finish << true
    request.join

    assert_equal ['GET /somewhere (no route): insert stashes'], GetWrites.disallowed.map(&:to_s)
    assert_equal 1, GetWrites.writes.length
    GetWrites.start(self)
  end

  test "a request from an earlier test that finishes in this one isn't blamed on it" do
    started = Queue.new
    finish = Queue.new
    request = Thread.new do
      request_through_middleware do
        started << true
        finish.pop
        Stash.create!(key: 'late', value: 'x')
      end
    end
    started.pop
    GetWrites.start(Object.new) # as the next test's setup does
    finish << true
    request.join
    assert_empty GetWrites.writes
  ensure
    GetWrites.start(self)
  end
end
