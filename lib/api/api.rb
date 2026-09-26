module Dandelion
  module API
    class Error < StandardError
      attr_reader :status

      def initialize(message, status: 400)
        super(message)
        @status = status
      end
    end

    DEFAULT_LIMIT = 20
    MAX_LIMIT = 100
    MAX_SKIP = 10_000
    MAX_TIME_MS = 5_000
    MAX_FILTER_DEPTH = 5
    MAX_REGEX_LENGTH = 200
    LOGICAL_OPERATORS = %w[$and $or $nor].freeze
    FIELD_OPERATORS = %w[$eq $ne $gt $gte $lt $lte $in $nin $exists $not $regex $options $all $size].freeze
    REGEX_OPTIONS = /\A[imsx]*\z/
    BEARER_PATTERN = /\ABearer\s+(\S+)\z/i

    # nil when no Authorization header is sent, :invalid when it doesn't match an account
    def self.account_from_request(rack_request)
      header = rack_request.get_header('HTTP_AUTHORIZATION')
      return nil if header.blank?

      match = header.match(BEARER_PATTERN)
      return :invalid unless match

      Account.find_by(api_key: match[1]) || :invalid
    end

    def self.resources
      @resources ||= RESOURCE_DEFINITIONS.to_h { |name, definition| [name, Resource.new(name, definition)] }
    end

    def self.resource(name)
      resources[name.to_s] || raise(Error.new("Unknown resource #{name}. Available resources: #{resources.keys.join(', ')}", status: 404))
    end

    def self.describe
      resources.values.map(&:describe)
    end

    def self.find(account, resource_name, filter: nil, fields: nil, sort: nil, limit: nil, skip: nil)
      resource = resource(resource_name)
      fields = resource.output_fields(fields)
      limit = (limit || DEFAULT_LIMIT).to_i.clamp(1, MAX_LIMIT)
      skip = skip.to_i
      raise Error, "skip must be between 0 and #{MAX_SKIP}" unless skip.between?(0, MAX_SKIP)

      records = run_query do
        resource.criteria(account, filter).order(resource.sort(sort)).skip(skip).limit(limit + 1).to_a
      end
      has_more = records.length > limit
      {
        resource: resource.name,
        data: records.first(limit).map { |record| resource.serialize(record, account, fields) },
        limit: limit,
        skip: skip,
        has_more: has_more
      }
    end

    def self.count(account, resource_name, filter: nil)
      resource = resource(resource_name)
      count = run_query { resource.criteria(account, filter).count }
      { resource: resource.name, count: count }
    end

    def self.get(account, resource_name, id)
      resource = resource(resource_name)
      record = run_query { resource.criteria(account, { 'id' => id.to_s }).first }
      raise Error.new("#{resource.model.name} not found", status: 404) unless record

      resource.serialize(record, account, resource.output_fields(nil))
    end

    def self.run_query
      yield
    rescue Mongo::Error::OperationFailure => e
      raise Error.new('Query took too long. Narrow your filter.', status: 504) if e.code == 50

      raise Error, 'Invalid query'
    rescue ArgumentError, Mongoid::Errors::InvalidQuery
      raise Error, 'Invalid query value'
    end

    def self.json_value(value)
      case value
      when BSON::ObjectId, BSON::Decimal128 then value.to_s
      when Time, DateTime, Date, ActiveSupport::TimeWithZone then value.iso8601
      when Array then value.map { |v| json_value(v) }
      when Hash then value.to_h { |k, v| [k.to_s, json_value(v)] }
      else value
      end
    end

    class Resource
      attr_reader :name, :definition

      def initialize(name, definition)
        @name = name
        @definition = definition
      end

      def model
        definition[:model].constantize
      end

      def fields
        definition[:fields]
      end

      def readable_fields
        fields + definition.fetch(:private_fields, []) + definition.fetch(:extra_fields, [])
      end

      def describe
        {
          name: name,
          description: definition[:description],
          fields: readable_fields,
          filterable_fields: fields
        }
      end

      def criteria(account, filter)
        filter ||= {}
        raise Error, 'filter must be an object' unless filter.is_a?(Hash)

        scope = model.readable_by(account)
        scope = scope.without(*definition[:exclude]) if definition[:exclude]
        scope = scope.includes(*definition[:includes]) if definition[:includes]
        scope = scope.and('$and' => [translate_filter(filter.deep_stringify_keys)]) if filter.any?
        scope.max_time_ms(MAX_TIME_MS)
      end

      def sort(sort)
        return { '_id' => -1 } if sort.blank?
        raise Error, 'sort must be an object, e.g. {"start_time": 1}' unless sort.is_a?(Hash)

        sort.to_h do |field, direction|
          field = field.to_s
          raise Error, "Cannot sort by #{field}. Sortable fields: #{fields.join(', ')}" unless fields.include?(field)

          direction = { '1' => 1, 'asc' => 1, '-1' => -1, 'desc' => -1 }[direction.to_s.downcase]
          raise Error, 'sort direction must be 1, -1, "asc" or "desc"' unless direction

          [storage_name(field), direction]
        end
      end

      def output_fields(requested)
        return readable_fields if requested.blank?
        raise Error, 'fields must be an array of field names' unless requested.is_a?(Array)

        requested = requested.map(&:to_s)
        unknown = requested - readable_fields
        raise Error, "Unknown fields: #{unknown.join(', ')}. Readable fields: #{readable_fields.join(', ')}" if unknown.any?

        (['id'] + requested).uniq
      end

      def serialize(record, account, output_fields)
        extra_fields = definition.fetch(:extra_fields, [])
        data = {}
        output_fields.each do |field|
          data[field] = API.json_value(record.attributes[storage_name(field)]) unless extra_fields.include?(field)
        end
        if output_fields.intersect?(extra_fields)
          extras = definition[:extras].call(record, account).stringify_keys
          (output_fields & extra_fields).each { |field| data[field] = API.json_value(extras[field]) }
        end
        data
      end

      private

      def storage_name(field)
        field == 'id' ? '_id' : field
      end

      def string_field?(field)
        model.fields[storage_name(field)]&.type == String
      end

      def translate_filter(filter, depth = 0)
        raise Error, "filter is nested too deeply (max #{MAX_FILTER_DEPTH} levels)" if depth > MAX_FILTER_DEPTH

        filter.to_h do |key, value|
          if LOGICAL_OPERATORS.include?(key)
            raise Error, "#{key} must be a non-empty array of filters" unless value.is_a?(Array) && value.any? && value.all?(Hash)

            [key, value.map { |condition| translate_filter(condition, depth + 1) }]
          elsif key.start_with?('$')
            raise Error, "Operator #{key} is not allowed here. Top-level operators: #{LOGICAL_OPERATORS.join(', ')}"
          elsif fields.include?(key)
            [storage_name(key), translate_condition(key, value)]
          else
            raise Error, "Cannot filter by #{key}. Filterable fields: #{fields.join(', ')}"
          end
        end
      end

      def translate_condition(field, condition)
        return scalar_value(field, condition) unless condition.is_a?(Hash)
        raise Error, "Empty condition for #{field}" if condition.empty?

        raise Error, '$options can only be used with $regex' if condition.key?('$options') && !condition.key?('$regex')

        condition.to_h do |operator, value|
          raise Error, "Operator #{operator} is not allowed. Allowed operators: #{FIELD_OPERATORS.join(', ')}" unless FIELD_OPERATORS.include?(operator)

          value = case operator
                  when '$in', '$nin', '$all'
                    raise Error, "#{operator} must be an array" unless value.is_a?(Array)

                    value.map { |v| scalar_value(field, v) }
                  when '$exists'
                    raise Error, '$exists must be true or false' unless [true, false].include?(value)

                    value
                  when '$size'
                    raise Error, '$size must be a non-negative integer' unless value.is_a?(Integer) && value >= 0

                    value
                  when '$not'
                    raise Error, '$not must be an object of operators' unless value.is_a?(Hash)

                    translate_condition(field, value)
                  when '$regex'
                    regex_value(field, value)
                  when '$options'
                    raise Error, '$options may only contain i, m, s and x' unless value.is_a?(String) && value.match?(REGEX_OPTIONS)

                    value
                  else
                    scalar_value(field, value)
                  end
          [operator, value]
        end
      end

      def scalar_value(field, value)
        raise Error, "Invalid value for #{field}: use a string, number, boolean or null" unless value.nil? || value.is_a?(String) || value.is_a?(Numeric) || [true, false].include?(value)

        value
      end

      def regex_value(field, value)
        raise Error, "$regex can only be used on text fields, not #{field}" unless string_field?(field)
        raise Error, "$regex must be a string of at most #{MAX_REGEX_LENGTH} characters" unless value.is_a?(String) && value.length <= MAX_REGEX_LENGTH

        value
      end
    end
  end
end
