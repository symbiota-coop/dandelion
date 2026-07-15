require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class LocalGroupsTest < ActiveSupport::TestCase
  include Capybara::DSL

  test 'creating a local group' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @local_group = FactoryBot.build_stubbed(:local_group)
    login_as(@account)
    visit "/o/#{@organisation.slug}"
    click_link 'Create a local group'
    fill_in 'Name', with: @local_group.name
    fill_in 'Geometry', with: @local_group.geometry
    click_button 'Create local group'
    assert page.has_content? 'The local group was created'
  end

  test 'editing a local group' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @local_group = FactoryBot.create(:local_group, organisation: @organisation, account: @account)
    login_as(@account)
    visit "/local_groups/#{@local_group.id}/edit"
    fill_in 'Name', with: (name = FactoryBot.build_stubbed(:local_group).name)
    click_button 'Update local group'
    assert page.has_content? 'The local group was saved'
    assert page.has_content? name
  end

  test 'invalid geometry does not delete persisted polygons' do
    local_group = FactoryBot.create(:local_group)
    original_polygons = local_group.reload.polygons.map { |polygon| [polygon.id, polygon.coordinates] }
    refute_empty original_polygons

    refute local_group.update_attributes(geometry: { type: 'Point', coordinates: [-0.12, 51.5] }.to_json)
    assert_includes local_group.errors[:geometry], 'must be a GeoJSON Polygon or MultiPolygon'

    assert_equal original_polygons, (local_group.reload.polygons.map { |polygon| [polygon.id, polygon.coordinates] })
  end

  test 'another validation failure does not delete persisted polygons' do
    organisation = FactoryBot.create(:organisation)
    local_group = FactoryBot.create(:local_group, organisation: organisation)
    another_local_group = FactoryBot.create(:local_group, organisation: organisation)
    original_polygons = local_group.reload.polygons.map { |polygon| [polygon.id, polygon.coordinates] }

    refute local_group.update_attributes(slug: another_local_group.slug)

    assert_equal original_polygons, (local_group.reload.polygons.map { |polygon| [polygon.id, polygon.coordinates] })
  end
end
