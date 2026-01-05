module CoreExtensions
  extend ActiveSupport::Concern

  # Fields to auto-strip HTML from
  SANITIZED_FIELDS = %i[name title subject].freeze

  included do
    after_initialize :convert_nil_booleans_to_false
    before_validation :convert_nil_booleans_to_false
    before_validation :sanitize_fields
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

    # Example:
    # has_many_through :followers, class_name: 'Account', through: :follows_as_followee, foreign_key: :follower_id
    # creates:
    # def follower_ids
    #   follows_as_followee.pluck(:follower_id)
    # end
    # def followers
    #   Account.and(:id.in => follower_ids)
    # end
    def has_many_through(name, through:, class_name: nil, foreign_key: nil, conditions: nil) # rubocop:disable Naming/PredicatePrefix
      class_name_string = class_name || name.to_s.singularize.camelize

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

  private

  def sanitize_fields
    CoreExtensions::SANITIZED_FIELDS.each do |field|
      next unless respond_to?(field) && respond_to?("#{field}=")

      value = send(field)
      next unless value.present?

      send("#{field}=", Sanitize.fragment(value.to_s))
    end
  end
end
