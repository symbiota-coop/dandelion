module DandelionMongo
  extend ActiveSupport::Concern

  included do
    after_initialize :convert_nil_booleans_to_false
    before_validation :convert_nil_booleans_to_false
  end

  def convert_nil_booleans_to_false
    self.class.fields.each do |field_name, field|
      send("#{field_name}=", false) if field.type == Mongoid::Boolean && send(field_name).nil?
    end
  end

  class_methods do
    def belongs_to_without_parent_validation(name, **opts)
      original_opts = opts.dup

      opts[:optional]  = true
      opts[:validate]  = false

      belongs_to(name, **opts)

      return if original_opts[:optional] == true

      # otherwise, validate the presence of a parent id (and type if polymorphic)
      # and that the actual object exists

      validates_presence_of :"#{name}_id"

      if opts[:polymorphic]
        validates_presence_of :"#{name}_type"
        validate :"validate_#{name}_exists"

        define_method "validate_#{name}_exists" do
          return unless send("#{name}_id").present? && send("#{name}_type").present?

          klass = begin
            send("#{name}_type").constantize
          rescue StandardError
            nil
          end
          return errors.add(:"#{name}_type", 'is not a valid class') unless klass

          # Check if the parent exists in memory first (for nested attributes)
          return if send(name).present?

          return if klass.where(id: send("#{name}_id")).exists?

          errors.add(:"#{name}", 'does not exist')
        end
      else
        validate :"validate_#{name}_exists"

        define_method "validate_#{name}_exists" do
          return unless send("#{name}_id").present?

          # Check if the parent exists in memory first (for nested attributes)
          return if send(name).present?

          association_class = self.class.reflect_on_association(name.to_sym).klass
          return if association_class.where(id: send("#{name}_id")).exists?

          errors.add(:"#{name}", 'does not exist')
        end
      end
    end

    # Define a method that returns IDs from an association
    # and automatically creates a corresponding method that returns the model objects
    #
    # Examples:
    #   has_many_through :event_tags, through: :event_tagships
    #   # Infers class_name 'EventTag' from :event_tags
    #   # Creates:
    #   #   def event_tag_ids
    #   #     event_tagships.pluck(:event_tag_id)
    #   #   end
    #   #   def event_tags
    #   #     EventTag.and(:id.in => event_tag_ids)
    #   #   end
    #
    #   has_many_through :members, class_name: 'Account', through: :local_groupships
    #   # Explicit class_name when it can't be inferred from name
    #
    #   has_many_through :admins, class_name: 'Account', through: :local_groupships, conditions: { admin: true }
    #   # With conditions:
    #   #   def admin_ids
    #   #     local_groupships.and(admin: true).pluck(:account_id)
    #   #   end
    #   #   def admins
    #   #     Account.and(:id.in => admin_ids)
    #   #   end
    #
    #   has_many_through :following, class_name: 'Account', through: :follows_as_follower, foreign_key: :followee_id
    #   # With custom foreign_key
    #
    #   with_options class_name: 'Account', through: :organisationships do
    #     has_many_through :admins, conditions: { admin: true }
    #     has_many_through :members
    #   end
    #   # Use with_options to DRY up multiple collections with shared options
    def has_many_through(name, through:, class_name: nil, foreign_key: nil, conditions: nil) # rubocop:disable Naming/PredicatePrefix
      # Store the class_name string for later constantization
      class_name_string = class_name || name.to_s.singularize.camelize

      # Infer the foreign key from the class name string if not provided
      fk = foreign_key || "#{class_name_string.underscore}_id"

      ids_method = "#{name.to_s.singularize}_ids"
      collection_method = name

      define_method(ids_method) do
        scope = send(through)
        scope = scope.and(conditions) if conditions
        scope.pluck(fk)
      end

      define_method(collection_method) do
        # Constantize at runtime instead of at class definition time
        model_class = class_name_string.constantize
        model_class.and(:id.in => send(ids_method))
      end
    end
  end
end
