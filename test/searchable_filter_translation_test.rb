require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class SearchableFilterTranslationTest < ActiveSupport::TestCase
  class CapturingCollection
    attr_reader :pipelines

    def initialize
      @pipelines = []
    end

    def aggregate(pipeline, **_kwargs)
      @pipelines << pipeline
      []
    end
  end

  test 'pushes supported organisation event filters into atlas search' do
    collection = CapturingCollection.new
    organisation_id = BSON::ObjectId.new
    from = Time.utc(2026, 7, 4, 23)
    scope = Event.unscoped
                 .or({ organisation_id: organisation_id }, { cohosts_ids_cache: organisation_id })
                 .and(deleted_at: nil)
                 .and(secret: false)
                 .future_current_evergreen(from)

    Event.stub(:collection, collection) do
      Event.search('Sound', scope, regex_search: false)
    end

    filter = search_filter_for(collection.pipelines.first)
    suffix_match = suffix_match_for(collection.pipelines.first)

    assert_includes equals_filters(filter), ['organisation_id', organisation_id]
    assert_includes equals_filters(filter), ['cohosts_ids_cache', organisation_id]
    assert_includes equals_filters(filter), ['secret', false]
    assert_includes range_filters(filter), ['start_time', :gte, from]
    assert_includes range_filters(filter), ['end_time', :gte, from]
    assert_includes equals_filters(filter), ['show_after_start_time', true]
    assert_includes equals_filters(filter), ['evergreen', true]

    refute suffix_match.keys.map(&:to_s).include?('$or')
    assert_equal({ 'deleted_at' => nil }, stringify_keys(suffix_match))
  end

  test 'leaves unsupported or branch in post search match' do
    collection = CapturingCollection.new
    organisation_id = BSON::ObjectId.new
    scope = Event.unscoped.or({ organisation_id: organisation_id }, { deleted_at: nil })

    Event.stub(:collection, collection) do
      Event.search('Sound', scope, regex_search: false)
    end

    filter = search_filter_for(collection.pipelines.first)
    suffix_match = suffix_match_for(collection.pipelines.first)

    refute_includes equals_filters(filter), ['organisation_id', organisation_id]
    assert suffix_match.keys.map(&:to_s).include?('$or')
  end

  private

  def search_filter_for(pipeline)
    pipeline.first.fetch(:"$search").fetch(:compound).fetch(:filter)
  end

  def suffix_match_for(pipeline)
    pipeline.find { |stage| stage.key?(:"$match") }.fetch(:"$match")
  end

  def equals_filters(node)
    case node
    when Array
      node.flat_map { |item| equals_filters(item) }
    when Hash
      if node[:equals]
        [[node[:equals][:path], node[:equals][:value]]]
      elsif node[:compound]
        equals_filters(node[:compound][:filter]) + equals_filters(node[:compound][:should])
      else
        []
      end
    else
      []
    end
  end

  def range_filters(node)
    case node
    when Array
      node.flat_map { |item| range_filters(item) }
    when Hash
      if node[:range]
        node[:range].except(:path).map { |operator, value| [node[:range][:path], operator, value] }
      elsif node[:compound]
        range_filters(node[:compound][:filter]) + range_filters(node[:compound][:should])
      else
        []
      end
    else
      []
    end
  end

  def stringify_keys(hash)
    hash.transform_keys(&:to_s)
  end
end
