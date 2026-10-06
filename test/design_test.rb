require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

# The design guide renders the real partials with unsaved sample records (app/helpers/design_helpers.rb),
# so a partial that starts querying or saving can break it, or make it write to the database
class DesignTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  # Every collection's document count, less page views, which every request records
  def document_counts
    Mongoid.default_client.database.collection_names.reject { |name| name == 'page_views' }.sort.to_h do |name|
      [name, Mongoid.default_client[name].count_documents]
    end
  end

  def assert_design_guide_renders_without_writing
    counts = document_counts
    get '/design'
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Breathwork and sound journey'
    assert_equal counts, document_counts
  end

  test 'the design guide renders signed out without writing to the database' do
    assert_design_guide_renders_without_writing
  end

  test 'the design guide renders signed in without writing to the database' do
    sign_in_with_rack(FactoryBot.create(:account))
    assert_design_guide_renders_without_writing
  end

  test 'has_many_through reads an unsaved record\'s built join documents' do
    event = FactoryBot.build(:event)
    event.event_tagships.build(event_tag: EventTag.new(name: 'breathwork'))
    assert_equal ['breathwork'], event.event_tags.map(&:name)
    assert_empty FactoryBot.build(:event).event_tags.to_a
  end
end
