module BelongsToWithoutParentValidation
  extend ActiveSupport::Concern

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
  end
end
