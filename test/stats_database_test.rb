require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class StatsDatabaseTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  # reset! empties only the app's models, so each test starts this collection afresh: an index an earlier test's
  # queries used would count as used, and offer no Drop
  setup do
    Mongoid.default_client[:leftover_things].drop
  end

  test 'an admin sees each collection, and flags one no model uses' do
    Mongoid.default_client[:leftover_things].insert_one(name: 'x')
    sign_in(FactoryBot.create(:account, admin: true))

    visit '/stats/collections'
    within('tr', text: 'leftover_things') { assert page.has_content? 'No model' }
    within('tr', text: /\Aaccounts\b/) { assert page.has_no_content? 'No model' }
  end

  test 'an admin sees indexes, with unused ones flagged and TTL ones not' do
    Mongoid.default_client[:leftover_things].indexes.create_one({ name: 1 }, name: 'leftover_name')
    Mongoid.default_client[:leftover_things].indexes.create_one({ created_at: 1 }, name: 'created_at_ttl', expire_after: 3600)
    sign_in(FactoryBot.create(:account, admin: true))

    visit '/stats/indexes'
    within('tr', text: 'leftover_name') { assert page.has_content? 'Unused' }
    within('tr', text: 'created_at_ttl') do
      assert page.has_content? 'TTL: 1 hour'
      assert page.has_no_content? 'Unused'
    end

    check 'Unused only'
    assert page.has_field? 'unused', checked: true
    assert page.has_content? 'leftover_name'
    assert page.has_no_content? 'created_at_ttl'
  end

  test 'an admin drops an unused index' do
    leftover = Mongoid.default_client[:leftover_things]
    leftover.indexes.create_one({ name: 1 }, name: 'leftover_name')
    sign_in(FactoryBot.create(:account, admin: true))

    visit '/stats/indexes'
    within('tr', text: 'leftover_name') { click_button_and_confirm 'Drop' }
    assert page.has_content? 'Dropped leftover_name from leftover_things'
    assert_equal(%w[_id_], leftover.indexes.map { |index| index['name'] })
  end

  test 'indexes code hints and the plain index beside a filtered one offer no drop' do
    Mongoid.default_client[:leftover_things].indexes.create_many([{ key: { slug: 1 }, name: 'slug_1' },
                                                                  { key: { slug: 1 }, name: 'slug_1_unique', unique: true, partial_filter_expression: { slug: { '$type' => 'string' } } }])
    Event.collection.indexes.create_one({ hosts_ids_cache: 1, deleted_at: 1, secret: 1, start_time: 1 }, name: Event::HOSTS_INDEX)
    sign_in(FactoryBot.create(:account, admin: true))

    visit '/stats/indexes'
    within('tr', text: /\Aslug_1 /) do
      assert page.has_content? 'Beside a filtered index'
      assert page.has_no_button? 'Drop'
    end
    within('tr', text: 'slug_1_unique') { assert page.has_button? 'Drop' }
    within('tr', text: Event::HOSTS_INDEX) do
      assert page.has_content? 'Hinted by code'
      assert page.has_no_button? 'Drop'
    end
  end

  test 'the drop route refuses an index the page keeps, or one in use' do
    Event.collection.indexes.create_one({ hosts_ids_cache: 1, deleted_at: 1, secret: 1, start_time: 1 }, name: Event::HOSTS_INDEX)
    leftover = Mongoid.default_client[:leftover_things]
    leftover.indexes.create_one({ name: 1 }, name: 'leftover_name')
    leftover.find(name: 'x').to_a
    sign_in_with_rack(FactoryBot.create(:account, admin: true))

    post '/stats/indexes/drop', collection: Event.collection.name, name: Event::HOSTS_INDEX
    assert_equal 400, last_response.status
    post '/stats/indexes/drop', collection: 'leftover_things', name: 'leftover_name'
    assert_equal 400, last_response.status
    post '/stats/indexes/drop', collection: 'leftover_things', name: '_id_'
    assert_equal 400, last_response.status
    assert_includes Event.collection.indexes.map { |index| index['name'] }, Event::HOSTS_INDEX
    assert_includes leftover.indexes.map { |index| index['name'] }, 'leftover_name'
  end

  test 'only admins can see /stats/collections or /stats/indexes, or drop an index' do
    Mongoid.default_client[:leftover_things].indexes.create_one({ name: 1 }, name: 'leftover_name')
    sign_in_with_rack(FactoryBot.create(:account))
    %w[/stats/collections /stats/indexes].each do |path|
      get path
      assert last_response.redirect?, path
    end
    post '/stats/indexes/drop', collection: 'leftover_things', name: 'leftover_name'
    assert last_response.redirect?
    assert_includes Mongoid.default_client[:leftover_things].indexes.map { |index| index['name'] }, 'leftover_name'
  end
end
