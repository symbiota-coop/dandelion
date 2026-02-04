module Taggable
  extend ActiveSupport::Concern

  class_methods do
    def taggable(tagships:, tag_class:, update_flag: false, store_field: nil)
      attr_accessor :tag_names
      attr_accessor :update_tag_names if update_flag

      after_save :update_tags

      tag_name_method = :"#{tag_class.name.underscore}_name"

      define_method(:taggable_config) do
        {
          tagships: tagships,
          tag_class: tag_class,
          tag_name_method: tag_name_method,
          update_flag: update_flag,
          store_field: store_field
        }
      end

      define_method(:update_tags) do
        return if taggable_config[:update_flag] && !@update_tag_names

        @tag_names ||= []
        new_tag_names = @tag_names.flatten.map(&:strip).reject(&:blank?)
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

        if taggable_config[:store_field]
          set(taggable_config[:store_field] => send(taggable_config[:tagships], true).map(&taggable_config[:tag_name_method]))
        end
      end

      define_method(:tag_names_for_form) do
        tag_names.presence || send(taggable_config[:tagships]).map(&taggable_config[:tag_name_method])
      end
    end
  end
end
