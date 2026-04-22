namespace :db do
  desc 'Find accounts where organisation cache fields are out of sync (FIX=1 to repair)'
  task organisation_cache_sync: :environment do
    fix = ENV['FIX'] == '1'

    puts "\n🔍 Checking organisation cache sync for all accounts...\n"
    puts "⚠️  Mode: #{fix ? '🔧 FIXING out of sync caches' : '👀 Dry run (set FIX=1 to repair)'}\n"
    puts '=' * 90

    puts '📊 Aggregating organisationships...'
    out_of_sync = Account.check_organisation_cache_sync(fix: fix)

    if out_of_sync.empty?
      puts "\n✅ All accounts have synced organisation caches.\n\n"
    else
      puts "\n📋 Accounts with out of sync caches:\n"
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
      puts "📊 Found #{out_of_sync.length} account(s) with out of sync caches"
      puts(fix ? '🎉 All caches have been repaired!' : '👉 Run with FIX=1 to repair them')
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
end
