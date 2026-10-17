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

  test 'theme.css darkens a theme colour too light for white text, keeping its hue, and lightens one too dark' do
    get '/theme.css', theme_color: '00af5e'
    assert_includes last_response.body, '--theme-500: #00af5e;'
    assert_includes last_response.body, '--theme-500-rgb: 0, 175, 94;'

    # Yellow darkens to the lightest shade with a 2:1 contrast against white
    get '/theme.css', theme_color: '#ffc107'
    assert_includes last_response.body, '--theme-500: #e6ac00;'
    assert_in_delta 2.05, ColorMath.contrast('#e6ac00', '#fff'), 0.01
    assert_equal ColorMath.hsl('#ffc107')[0].round, ColorMath.hsl('#e6ac00')[0].round

    get '/theme.css', theme_color: '#fff'
    assert_includes last_response.body, '--theme-500: #b5b5b5;'

    # Near black lightens to 25% lightness
    get '/theme.css', theme_color: '#1a0000'
    assert_includes last_response.body, '--theme-500: #800000;'
  end

  test 'email theme css darkens the theme for hovers and fades it for blockquote borders' do
    css = EmailHelper.theme_css('#00af5e')
    assert_includes css, 'a:hover { color: #009650 !important; }'
    assert_includes css, 'border-left: 0.25em solid rgba(0, 175, 94, 0.33)'
    assert_includes EmailHelper.theme_css('Blue'), 'a:hover { color: Blue !important; }'
  end

  test 'has_many_through reads an unsaved record\'s built join documents' do
    event = FactoryBot.build(:event)
    event.event_tagships.build(event_tag: EventTag.new(name: 'breathwork'))
    assert_equal ['breathwork'], event.event_tags.map(&:name)
    assert_empty FactoryBot.build(:event).event_tags.to_a
  end
end
