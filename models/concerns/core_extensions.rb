module CoreExtensions
  extend ActiveSupport::Concern

  # Fields to auto-strip HTML from
  SANITIZED_FIELDS = %i[name title subject].freeze

  # Fields to exclude from auto-generated admin_fields
  ADMIN_FIELDS_EXCLUDED = %w[_id _type created_at updated_at deleted_at crypted_password].freeze

  # Field name patterns that suggest specific admin field types
  ADMIN_FIELD_PATTERNS = {
    email: /\Aemail\z/,
    url: /(\A|_)url\z|website/,
    slug: /\Aslug\z/
  }.freeze

  included do
    after_initialize :convert_nil_booleans_to_false
    before_validation :convert_nil_booleans_to_false
    before_validation :sanitize_fields
  end

  def convert_nil_booleans_to_false
    self.class.fields.each do |field_name, field|
      send("#{field_name}=", false) if field.type == Mongoid::Boolean && send(field_name).nil?
    rescue Mongoid::Errors::AttributeNotLoaded
      next
    end
  end

  class_methods do
    def admin_fields
      auto_admin_fields
    end

    def auto_admin_fields
      result = {}

      # 1. Add first identifying field (summary method, or name/title/subject field)
      if method_defined?(:summary)
        result[:summary] = { type: :text, edit: false }
      else
        found_identifying_field = false
        SANITIZED_FIELDS.map(&:to_s).each do |f|
          next unless fields.key?(f)

          result[f.to_sym] = { type: :text, full: true }
          found_identifying_field = true
          break
        end
        result[:id] = { type: :text, disabled: true } unless found_identifying_field
      end
      result[:email] = :email if fields.key?('email')
      result[:password] = :password if method_defined?(:password)

      # Prep: Detect dragonfly accessors (must have *_uid field AND dragonfly accessor method)
      dragonfly_fields = fields.keys.select { |f| f.end_with?('_uid') }.map { |f| f.sub(/_uid\z/, '') }.select do |name|
        # Dragonfly creates a *_stored? method for actual accessors
        method_defined?(:"#{name}_stored?")
      end
      belongs_to_fields = reflect_on_all_associations(:belongs_to).flat_map do |assoc|
        assoc.polymorphic? ? ["#{assoc.name}_id", "#{assoc.name}_type"] : ["#{assoc.name}_id"]
      end

      # Prep: Collect checkboxes separately
      checkboxes = {}
      fields.keys.sort.each do |field_name|
        field_def = fields[field_name]
        next unless field_def.type.to_s =~ /Boolean|TrueClass|FalseClass/
        next if ADMIN_FIELDS_EXCLUDED.include?(field_name)

        checkboxes[field_name.to_sym] = { type: :check_box, index: false }
      end

      # 2. Add checkboxes (sorted alphabetically, before belongs_to)
      checkboxes.each { |k, v| result[k] = v }

      # 3. Add belongs_to associations as :lookup (sorted alphabetically)
      reflect_on_all_associations(:belongs_to).sort_by(&:name).each do |assoc|
        if assoc.polymorphic?
          result[:"#{assoc.name}_type"] = :select
          result[:"#{assoc.name}_id"] = :text
        else
          result[:"#{assoc.name}_id"] = :lookup
        end
      end

      # 4. Add has_many associations as :collection (sorted alphabetically)
      reflect_on_all_associations(:has_many).sort_by(&:name).each do |assoc|
        next if assoc.options[:as] # Skip polymorphic (as: :notifiable etc)

        result[assoc.name] = :collection
      end

      # 5. Process Mongoid fields (sorted alphabetically, excluding checkboxes)
      fields.keys.sort.each do |field_name|
        field_def = fields[field_name]
        next if ADMIN_FIELDS_EXCLUDED.include?(field_name)
        next if dragonfly_fields.any? { |df| field_name == "#{df}_uid" } # Skip dragonfly uid fields only
        next if belongs_to_fields.include?(field_name) # Skip belongs_to foreign keys
        next if checkboxes.key?(field_name.to_sym) # Skip checkboxes (already added)

        # Skip dragonfly cache fields (e.g., image_cache if image is a dragonfly accessor)
        if field_name.end_with?('_cache')
          base_field = field_name.sub(/_cache\z/, '')
          next if dragonfly_fields.include?(base_field)
        end

        admin_type = mongoid_type_to_admin_type(field_name, field_def.type)
        result[field_name.to_sym] = admin_type if admin_type
      end

      # 6. Add dragonfly accessors as :image or :file (sorted alphabetically)
      dragonfly_fields.sort.each do |df_field|
        result[df_field.to_sym] = df_field.include?('image') ? :image : :file
      end

      result
    end

    private

    def mongoid_type_to_admin_type(field_name, mongoid_type)
      case mongoid_type.to_s
      when 'String'
        string_field_admin_type(field_name)
      when 'Integer', 'Float', 'BigDecimal'
        :number
      when 'Mongoid::Boolean', 'Boolean', 'TrueClass', 'FalseClass'
        :check_box
      when 'Date'
        :date
      when 'Time', 'DateTime', 'ActiveSupport::TimeWithZone'
        :datetime
      when 'Array', 'Hash'
        { type: :text_area, disabled: true, index: false }
      when 'BSON::ObjectId'
        nil # Skip ObjectId fields
      else
        :text # Default fallback
      end
    end

    def string_field_admin_type(field_name)
      # Check if this field has a corresponding select options method
      return :select if select_method_for?(field_name)

      # Name and key fields get full width
      return { type: :text, full: true } if %w[name key].include?(field_name.to_s)

      ADMIN_FIELD_PATTERNS.each do |admin_type, pattern|
        return admin_type if field_name.to_s.match?(pattern)
      end
      :text_area
    end

    # Check if a select options method exists for this field
    # e.g., status -> statuses, type -> types, currency -> currencies
    # For polymorphic: commentable -> commentable_types
    def select_method_for?(field_name, polymorphic: false)
      field_str = field_name.to_s
      if polymorphic
        respond_to?(:"#{field_str}_types", true)
      else
        # Try pluralized form (e.g., statuses, types, currencies)
        respond_to?(:"#{field_str.pluralize}", true)
      end
    end

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

  def sanitize_fields
    CoreExtensions::SANITIZED_FIELDS.each do |field|
      next unless respond_to?(field) && respond_to?("#{field}=")

      value = send(field)
      next unless value.present?

      send("#{field}=", Nokogiri::HTML.fragment(value.to_s).text.squish)
    end
  end
end
