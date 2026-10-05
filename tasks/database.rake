namespace :db do
  desc 'Find accounts where organisation caches are out of sync or organisationships are duplicated (FIX=1 to repair)'
  task organisation_cache_sync: :environment do
    fix = ENV['FIX'] == '1'

    puts "\n🔍 Checking organisation cache sync for all accounts...\n"
    puts "⚠️  Mode: #{fix ? '🔧 FIXING out of sync caches and duplicate organisationships' : '👀 Dry run (set FIX=1 to repair)'}\n"
    puts '=' * 90

    puts '📊 Aggregating organisationships...'
    out_of_sync = Account.check_organisation_cache_sync(fix: fix)

    if out_of_sync.empty?
      puts "\n✅ All accounts have synced organisation caches and no duplicate organisationships.\n\n"
    else
      puts "\n📋 Accounts with out of sync caches or duplicate organisationships:\n"
      puts '-' * 90

      out_of_sync.each do |entry|
        account = entry[:account]
        puts "\n👤 #{account.name || 'No name'} (#{account.email || account.id})"
        puts "   Mismatched fields: #{entry[:mismatches].join(', ')}"

        entry[:mismatches].each do |field|
          details = entry[:details][field.to_sym]
          puts "   #{field}:"
          puts "     Current:  #{details[:current].empty? ? '[]' : details[:current]}"
          puts "     Expected: #{details[:expected].empty? ? '[]' : details[:expected]}"
        end

        puts "   Status: #{fix ? '✅ Fixed' : '⚠️  Needs fix'}"
      end

      puts "\n#{'=' * 90}"
      puts "📊 Found #{out_of_sync.length} account(s) with out of sync caches or duplicate organisationships"
      puts(fix ? '🎉 All caches and duplicates have been repaired!' : '👉 Run with FIX=1 to repair them')
      puts
    end
  end

  desc 'Find events where cohosts_ids_cache is out of sync (FIX=1 to repair)'
  task cohosts_cache_sync: :environment do
    fix = ENV['FIX'] == '1'

    puts "\n🔍 Checking cohosts_ids_cache sync for all events...\n"
    puts "⚠️  Mode: #{fix ? '🔧 FIXING out of sync caches' : '👀 Dry run (set FIX=1 to repair)'}\n"
    puts '=' * 90

    puts '📊 Aggregating cohostships...'
    out_of_sync = Event.check_cohosts_cache_sync(fix: fix)

    if out_of_sync.empty?
      puts "\n✅ All events have synced cohosts_ids_cache.\n\n"
    else
      puts "\n📋 Events with out of sync caches:\n"
      puts '-' * 90

      out_of_sync.each do |entry|
        event = entry[:event]
        puts "\n📅 #{event.name} (#{event.id})"
        puts "   Organisation: #{event.organisation&.name || 'None'}"
        puts '   cohosts_ids_cache:'
        puts "     Current:  #{entry[:current].empty? ? '[]' : entry[:current]}"
        puts "     Expected: #{entry[:expected].empty? ? '[]' : entry[:expected]}"
        puts "   Status: #{fix ? '✅ Fixed' : '⚠️  Needs fix'}"
      end

      puts "\n#{'=' * 90}"
      puts "📊 Found #{out_of_sync.length} event(s) with out of sync caches"
      puts(fix ? '🎉 All caches have been repaired!' : '👉 Run with FIX=1 to repair them')
      puts
    end
  end

  desc 'Find MongoDB collections without an associated Mongoid model'
  task orphan_collections: :environment do
    db = Mongoid.default_client.database
    db_collections = db.collections.map(&:name).reject { |n| n.start_with?('system.') }.to_set

    model_collections = ObjectSpace.each_object(Class).select do |c|
      c.name.present? && c.include?(Mongoid::Document) && !c.name.start_with?('Mongoid::')
    end.map { |m| m.collection.name }.to_set

    orphaned = (db_collections - model_collections).sort

    puts "\n🔍 Collections without associated models\n"
    puts '=' * 60
    if orphaned.empty?
      puts "✅ All collections have associated models.\n\n"
    else
      orphaned.each { |name| puts "  • #{name}" }
      puts "\n📊 Found #{orphaned.size} collection(s) without models\n\n"
    end
  end

  desc 'Get sizes of all MongoDB collections'
  task collection_sizes: :environment do
    db = Mongoid.default_client.database

    puts "\n📊 MongoDB Collection Sizes\n"
    puts '=' * 80

    collections = db.collections.sort_by { |c| c.name }

    # Get total database size
    db_stats = db.command(dbStats: 1).first
    total_size = db_stats['dataSize'] || 0
    total_storage = db_stats['storageSize'] || 0
    total_indexes = db_stats['indexSize'] || 0

    # Calculate collection sizes
    collection_data = collections.map do |collection|
      stats = db.command(collStats: collection.name).first
      {
        name: collection.name,
        count: collection.count,
        size: stats['size'] || 0,
        storage_size: stats['storageSize'] || 0,
        total_index_size: stats['totalIndexSize'] || 0,
        avg_obj_size: stats['avgObjSize'] || 0
      }
    end

    # Sort by storage size (descending)
    collection_data.sort_by! { |c| -c[:storage_size] }

    # Display results
    printf "%-30s %12s %15s %15s %15s %12s\n",
           'Collection', 'Documents', 'Data Size', 'Storage Size', 'Index Size', 'Avg Doc'
    puts '-' * 80

    collection_data.each do |data|
      printf "%-30s %12s %15s %15s %15s %12s\n",
             data[:name],
             data[:count].to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse,
             ActiveSupport::NumberHelper.number_to_human_size(data[:size]),
             ActiveSupport::NumberHelper.number_to_human_size(data[:storage_size]),
             ActiveSupport::NumberHelper.number_to_human_size(data[:total_index_size]),
             ActiveSupport::NumberHelper.number_to_human_size(data[:avg_obj_size])
    end

    puts '-' * 80
    printf "%-30s %12s %15s %15s %15s\n",
           'TOTAL',
           collection_data.sum { |c| c[:count] }.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse,
           ActiveSupport::NumberHelper.number_to_human_size(total_size),
           ActiveSupport::NumberHelper.number_to_human_size(total_storage),
           ActiveSupport::NumberHelper.number_to_human_size(total_indexes)

    puts "\n"
  end

  desc 'Find unused indexes across all collections (DROP=1 to drop them)'
  task unused_indexes: :environment do
    db = Mongoid.default_client.database
    collections = db.collections.sort_by { |c| c.name }
    drop = ENV['DROP'] == '1'

    total_wasted = 0
    total_unused = 0
    total_dropped = 0

    puts "\n🔍 Scanning all collections for unused indexes...\n"
    puts "⚠️  Mode: #{drop ? '🔴 DROPPING unused indexes' : '👀 Dry run (set DROP=1 to drop)'}"
    puts "ℹ️  TTL indexes are automatically excluded (used by background monitor, not queries)\n"

    collections.each do |collection|
      # Get index usage stats via $indexStats aggregation
      stats = collection.aggregate([{ '$indexStats' => {} }]).to_a
      # Get index sizes from collStats
      coll_stats = db.command(collStats: collection.name).first
      index_sizes = coll_stats['indexSizes'] || {}

      # Get TTL index names (they show 0 query ops but are used by background TTL monitor)
      ttl_index_names = collection.indexes.select { |idx| idx.key?('expireAfterSeconds') }.map { |idx| idx['name'] }

      unused = stats.select { |s| s['accesses']['ops'] == 0 }
                    .reject { |s| s['name'] == '_id_' } # never drop _id
                    .reject { |s| ttl_index_names.include?(s['name']) } # never drop TTL indexes

      next if unused.empty?

      puts "\n📦 #{collection.name} (#{unused.length} unused out of #{stats.length} indexes)"
      puts '-' * 90
      printf "  %-45s %10s %15s %10s\n", 'Index', 'Usage', 'Size', 'Status'
      puts '  ' + ('-' * 85)

      unused.sort_by { |s| -(index_sizes[s['name']] || 0) }.each do |s|
        size = index_sizes[s['name']] || 0
        total_wasted += size
        total_unused += 1

        if drop
          begin
            collection.indexes.drop_one(s['name'])
            total_dropped += 1
            printf "  %-45s %10d %15s %10s\n", s['name'], 0, ActiveSupport::NumberHelper.number_to_human_size(size), '✅ dropped'
          rescue Mongo::Error::OperationFailure => e
            printf "  %-45s %10d %15s %10s\n", s['name'], 0, ActiveSupport::NumberHelper.number_to_human_size(size), '❌ failed'
            puts "    Error: #{e.message}"
          end
        else
          printf "  %-45s %10d %15s\n", s['name'], 0, ActiveSupport::NumberHelper.number_to_human_size(size)
        end
      end
    end

    puts "\n#{'=' * 90}"
    if drop
      puts "🎉 Dropped #{total_dropped}/#{total_unused} unused indexes, freed ~#{ActiveSupport::NumberHelper.number_to_human_size(total_wasted)}"
    else
      puts "📊 Found #{total_unused} unused indexes wasting #{ActiveSupport::NumberHelper.number_to_human_size(total_wasted)}"
      puts '👉 Run with DROP=1 to drop them all'
    end
    puts
  end

  desc 'List all TTL indexes across collections'
  task ttl_indexes: :environment do
    db = Mongoid.default_client.database

    puts "\n⏰ TTL Indexes\n"
    puts '=' * 90

    ttl_indexes = []

    db.collections.sort_by(&:name).each do |collection|
      collection.indexes.each do |index|
        next unless index.key?('expireAfterSeconds')

        ttl_indexes << {
          collection: collection.name,
          index_name: index['name'],
          key: index['key'].keys.first,
          expire_after: index['expireAfterSeconds']
        }
      end
    end

    if ttl_indexes.empty?
      puts "No TTL indexes found.\n\n"
    else
      printf "%-30s %-25s %-20s %s\n", 'Collection', 'Index', 'Field', 'Expires After'
      puts '-' * 90

      ttl_indexes.each do |idx|
        expire_str = if idx[:expire_after].zero?
                       'at field value'
                     elsif idx[:expire_after] < 86_400
                       "#{idx[:expire_after] / 3600} hours"
                     elsif idx[:expire_after] < 2_592_000
                       "#{idx[:expire_after] / 86_400} days"
                     else
                       "#{idx[:expire_after] / 2_592_000} months (~#{idx[:expire_after] / 86_400} days)"
                     end

        printf "%-30s %-25s %-20s %s\n",
               idx[:collection],
               idx[:index_name],
               idx[:key],
               expire_str
      end

      puts '-' * 90
      puts "📊 Found #{ttl_indexes.length} TTL index(es)\n\n"
    end
  end

  desc 'Check every validates_uniqueness_of has a matching unique index (CREATE=1 to create missing ones)'
  task uniqueness_indexes: :environment do
    create = ENV['CREATE'] == '1'

    puts "\n🔍 Checking unique indexes for validates_uniqueness_of...\n"
    puts "⚠️  Mode: #{create ? '🔧 CREATING missing indexes' : '👀 Dry run (set CREATE=1 to create them)'}\n"
    puts '=' * 90

    bson_types = {
      String => 'string', Symbol => 'string', Mongoid::StringifiedSymbol => 'string',
      BSON::ObjectId => 'objectId', Integer => 'number', Float => 'number', BigDecimal => 'number',
      Time => 'date', DateTime => 'date', Date => 'date', Mongoid::Boolean => 'bool'
    }

    specs = {}
    skipped = []

    Mongoid.models.reject(&:embedded?).sort_by(&:name).each do |model|
      model.validators.grep(Mongoid::Validatable::UniquenessValidator).each do |validator|
        options = validator.options
        validator.attributes.each do |attribute|
          label = "#{model.name}: validates_uniqueness_of :#{attribute}#{", scope: #{options[:scope].inspect}" if options[:scope]}"

          if options[:if] || options[:unless]
            skipped << "#{label} (has if/unless, an index would be stricter than the validation)"
            next
          end

          association = model.relations[attribute.to_s]
          field = association&.stores_foreign_key? ? association.foreign_key : model.database_field_name(attribute)
          scope_fields = Array.wrap(options[:scope]).map { |s| model.database_field_name(s) }
          keys = (scope_fields + [field]).uniq.to_h { |k| [k, 1] }

          filter = options[:conditions] ? options[:conditions].call.selector.to_h : {}
          if options[:allow_nil] || options[:allow_blank]
            type = association&.stores_foreign_key? ? 'objectId' : bson_types[model.fields[field]&.type]
            if type
              filter[field] = { '$type' => type }
            else
              skipped << "#{label} (allow_nil on a #{model.fields[field]&.type} field, no $type to filter nils with)"
              next
            end
          end

          collation = ({ 'locale' => 'en', 'strength' => 2 } if options[:case_sensitive] == false)

          spec = { collection: model.collection_name.to_s, keys: keys, filter: filter, collation: collation }
          (specs[spec] ||= []) << label
        end
      end
    end

    missing = []

    specs.each do |spec, labels|
      collection = Mongoid.default_client[spec[:collection]]
      existing = begin
        collection.indexes.to_a
      rescue Mongo::Error::OperationFailure # collection doesn't exist yet
        []
      end

      # Any unique index on a subset of the keys, with the same (or no) partial filter, already enforces this
      covering = existing.find do |index|
        index['unique'] &&
          (index['key'].keys - spec[:keys].keys).empty? &&
          (index['partialFilterExpression'].nil? || index['partialFilterExpression'].to_h == spec[:filter]) &&
          (index['collation'].nil? ? spec[:collation].nil? : index['collation']['strength'] == spec[:collation]&.dig('strength'))
      end

      if covering
        puts "✅ #{spec[:collection]} #{spec[:keys].keys.join(', ')} (#{covering['name']})"
        next
      end

      pipeline = []
      pipeline << { '$match' => spec[:filter] } if spec[:filter].any?
      pipeline << { '$group' => { _id: spec[:keys].keys.to_h { |k| [k.tr('.', '_'), "$#{k}"] }, count: { '$sum' => 1 } } }
      pipeline << { '$match' => { count: { '$gt' => 1 } } }
      aggregate_options = spec[:collation] ? { collation: spec[:collation], allow_disk_use: true } : { allow_disk_use: true }
      duplicates = collection.aggregate(pipeline, aggregate_options).to_a

      missing << spec
      puts "\n❌ #{spec[:collection]} #{spec[:keys].keys.join(', ')}"
      labels.uniq.each { |label| puts "   From: #{label}" }
      puts "   Partial filter: #{spec[:filter].to_json}" if spec[:filter].any?
      puts "   Collation: #{spec[:collation].to_json}" if spec[:collation]

      if duplicates.any?
        puts "   ⚠️  #{duplicates.length} duplicate group(s), resolve them before the index can be created, e.g.:"
        duplicates.first(5).each { |d| puts "     #{d['_id'].to_json} × #{d['count']}" }
        next
      end

      next unless create

      # A plain index on the same keys holds the auto-generated name, so upgrade or replace it
      plain = existing.find { |index| !index['unique'] && index['key'].to_h == spec[:keys] }

      index_options = { unique: true }
      index_options[:partial_filter_expression] = spec[:filter] if spec[:filter].any?
      index_options[:collation] = spec[:collation] if spec[:collation]
      begin
        if plain && spec[:filter].empty? && spec[:collation].nil?
          # Convert in place (MongoDB 6.0+), so the collection is never without the index.
          # prepareUnique makes new duplicates fail first, then unique checks the existing data.
          database = Mongoid.default_client.database
          database.command(collMod: spec[:collection], index: { name: plain['name'], prepareUnique: true })
          begin
            database.command(collMod: spec[:collection], index: { name: plain['name'], unique: true })
          rescue Mongo::Error::OperationFailure
            database.command(collMod: spec[:collection], index: { name: plain['name'], prepareUnique: false })
            raise
          end
          puts "   🔧 Converted #{plain['name']} to unique"
        elsif plain
          # Can't add a partial filter or collation in place: build the new index under its own name, then drop the old one
          name = collection.indexes.create_one(spec[:keys], index_options.merge(name: "#{plain['name']}_unique"))
          collection.indexes.drop_one(plain['name'])
          puts "   🔧 Created #{name} and dropped #{plain['name']}"
        else
          name = collection.indexes.create_one(spec[:keys], index_options)
          puts "   🔧 Created #{name}"
        end
      rescue Mongo::Error::OperationFailure => e
        puts "   💥 #{e.message}"
      end
    end

    puts "\n#{'=' * 90}"
    if skipped.any?
      puts "\n⏭️  Skipped (handle by hand):"
      skipped.each { |s| puts "   #{s}" }
    end
    puts "\n📊 #{specs.length} unique index(es) needed, #{missing.length} missing"
    puts '👉 Run with CREATE=1 to create the missing ones that have no duplicates' if missing.any? && !create
    puts
  end
end
