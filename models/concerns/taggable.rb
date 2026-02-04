module Taggable
  extend ActiveSupport::Concern

  class_methods do
    def taggable(tagships:, tag_class:)
      field :tag_names_cache, type: Array

      attr_accessor :tag_names, :update_tag_names

      after_save :update_tags

      tag_name_method = :"#{tag_class.name.underscore}_name"

      define_method(:taggable_config) do
        {
          tagships: tagships,
          tag_class: tag_class,
          tag_name_method: tag_name_method
        }
      end

      define_method(:update_tags) do
        return unless @update_tag_names

        @tag_names ||= []
        @tag_names = @tag_names.split(',') if @tag_names.is_a?(String)
        new_tag_names = @tag_names.map(&:strip).reject(&:blank?)
        current_tag_names = send(taggable_config[:tagships]).map(&taggable_config[:tag_name_method])
        tags_to_remove = current_tag_names - new_tag_names
        tags_to_add = new_tag_names - current_tag_names

        tags_to_remove.each do |name|
          tag = taggable_config[:tag_class].find_by(name: name)
          send(taggable_config[:tagships]).find_by(taggable_config[:tag_class].name.underscore => tag)&.destroy
        end

        tags_to_add.each do |name|
          tag = taggable_config[:tag_class].find_or_create_by(name: name)
          send(taggable_config[:tagships]).create(taggable_config[:tag_class].name.underscore => tag) if tag.persisted?
        end

        set(tag_names_cache: send(taggable_config[:tagships], true).map(&taggable_config[:tag_name_method]))
      end

      define_method(:tag_names_for_form) do
        tag_names.presence || send(taggable_config[:tagships]).map(&taggable_config[:tag_name_method])
      end

      define_method(:populate_tag_names_cache) do
        set(tag_names_cache: send(taggable_config[:tagships]).map(&taggable_config[:tag_name_method]))
      end

      define_singleton_method(:populate_all_tag_names_cache) do
        all.each(&:populate_tag_names_cache)
      end
    end
  end
end
