require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class LocalGroupsTest < ActiveSupport::TestCase
  include Capybara::DSL

  test 'creating a local group' do
    create_organisation
    local_group = FactoryBot.build_stubbed(:local_group)
    sign_in(@account)
    visit "/o/#{@organisation.slug}"
    click_link 'Create a local group'
    fill_in 'Name', with: local_group.name
    fill_in 'Geometry', with: local_group.geometry
    click_button 'Create local group'
    assert page.has_content? 'The local group was created'
  end

  test 'editing a local group' do
    create_organisation
    local_group = FactoryBot.create(:local_group, organisation: @organisation)
    sign_in(@account)
    visit "/local_groups/#{local_group.id}/edit"
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

  test 'a polygon with a hole keeps the hole, and members in the hole are not added' do
    outer = [[0, 0], [10, 0], [10, 10], [0, 10], [0, 0]]
    hole = [[4, 4], [4, 6], [6, 6], [6, 4], [4, 4]]
    local_group = FactoryBot.create(:local_group, geometry: { type: 'Polygon', coordinates: [outer, hole] }.to_json)

    assert_equal({ 'type' => 'Polygon', 'coordinates' => [outer, hole] }, local_group.reload.area)
    assert_equal [[outer, hole]], local_group.polygons.map(&:coordinates)

    organisation = local_group.organisation
    inside = FactoryBot.create(:account)
    inside.set(coordinates: [2, 2])
    in_hole = FactoryBot.create(:account)
    in_hole.set(coordinates: [5, 5])
    assert_equal [local_group], Organisationship.new(organisation: organisation, account: inside).relevant_local_groups.to_a
    assert_empty Organisationship.new(organisation: organisation, account: in_hole).relevant_local_groups.to_a
  end

  test 'a self-intersecting polygon is rejected' do
    bowtie = [[0, 0], [10, 10], [10, 0], [0, 10], [0, 0]]
    local_group = FactoryBot.build(:local_group, geometry: { type: 'Polygon', coordinates: [bowtie] }.to_json)

    refute local_group.save
    assert_includes local_group.errors[:geometry], 'is not a valid shape (check for crossing edges and unclosed rings)'
  end

  test 'organisation_id and account_id cannot be reassigned on update' do
    local_group = FactoryBot.create(:local_group)
    assert_cannot_reassign_organisation_or_account(local_group)
  end
end
