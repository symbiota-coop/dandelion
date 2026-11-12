require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class StatsDatabaseTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  # reset! empties only the app's models, so each test starts this collection afresh: an index an earlier test's
  # queries used would count as used
  setup do
    Mongoid.default_client[:leftover_things].drop
  end

  test 'an admin sees each collection, and flags one no model uses' do
    Mongoid.default_client[:leftover_things].insert_one(name: 'x')
    sign_in(FactoryBot.create(:account, admin: true))

    visit '/stats/collections'
    within('#collections-table tr', text: 'leftover_things') { assert page.has_content? 'No model' }
    within('#collections-table tr', text: /\Aaccounts\b/) { assert page.has_no_content? 'No model' }
  end

  test "collections a gem's model uses, like delayed_job's, aren't flagged" do
    Delayed::Job.create!(handler: '--- !ruby/object:Object {}')
    sign_in(FactoryBot.create(:account, admin: true))

    visit '/stats/collections'
    within('#collections-table tr', text: Delayed::Job.collection.name) { assert page.has_no_content? 'No model' }
  end

  test 'an admin sees indexes, with unused ones flagged and TTL ones not' do
    Mongoid.default_client[:leftover_things].indexes.create_one({ name: 1 }, name: 'leftover_name')
    Mongoid.default_client[:leftover_things].indexes.create_one({ created_at: 1 }, name: 'created_at_ttl', expire_after: 3600)
    sign_in(FactoryBot.create(:account, admin: true))

    visit '/stats/indexes'
    within('#indexes-table tr', text: 'leftover_name') { assert page.has_content? 'Unused' }
    within('#indexes-table tr', text: 'created_at_ttl') do
      assert page.has_content? 'TTL: 1 hour'
      assert page.has_no_content? 'Unused'
    end

    check 'Unused only'
    assert page.has_field? 'unused', checked: true
    assert page.has_content? 'leftover_name'
    assert page.has_no_content? 'created_at_ttl'

    uncheck 'Unused only'
    assert page.has_field? 'unused', checked: false
    check 'TTL only'
    assert page.has_field? 'ttl', checked: true
    assert page.has_content? 'created_at_ttl'
    assert page.has_no_content? 'leftover_name'
  end

  test "a collection links to its own indexes" do
    Mongoid.default_client[:leftover_things].indexes.create_one({ name: 1 }, name: 'leftover_name')
    Mongoid.default_client[:other_leftovers].indexes.create_one({ title: 1 }, name: 'other_title')
    sign_in(FactoryBot.create(:account, admin: true))

    visit '/stats/collections'
    click_link 'leftover_things'
    assert page.has_content? 'leftover_name'
    assert page.has_no_content? 'other_title'
  ensure
    Mongoid.default_client[:other_leftovers].drop
  end

  test 'indexes code hints and the plain index beside a filtered one are marked to keep, and none can be dropped here' do
    Mongoid.default_client[:leftover_things].indexes.create_many([{ key: { slug: 1 }, name: 'slug_1' },
                                                                  { key: { slug: 1 }, name: 'slug_1_unique', unique: true, partial_filter_expression: { slug: { '$type' => 'string' } } }])
    Event.collection.indexes.create_one({ hosts_ids_cache: 1, deleted_at: 1, secret: 1, start_time: 1 }, name: Event::HOSTS_INDEX)
    sign_in(FactoryBot.create(:account, admin: true))

    visit '/stats/indexes'
    within('#indexes-table tr', text: /leftover_things\s+slug_1 /) { assert page.has_content? 'Beside a filtered index' }
    within('#indexes-table tr', text: 'slug_1_unique') { assert page.has_no_content? 'Beside a filtered index' }
    within('#indexes-table tr', text: Event::HOSTS_INDEX) { assert page.has_content? 'Hinted by code' }
    assert page.has_no_button? 'Drop'
  end

  test 'only admins can see /stats/collections or /stats/indexes' do
    sign_in_with_rack(FactoryBot.create(:account))
    %w[/stats/collections /stats/indexes].each do |path|
      get path
      assert last_response.redirect?, path
    end
  end
end
