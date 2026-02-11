namespace :db do
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
    puts "⚠️  Mode: #{drop ? '🔴 DROPPING unused indexes' : '👀 Dry run (set DROP=1 to drop)'}\n"

    collections.each do |collection|
      # Get index usage stats via $indexStats aggregation
      stats = collection.aggregate([{ '$indexStats' => {} }]).to_a
      # Get index sizes from collStats
      coll_stats = db.command(collStats: collection.name).first
      index_sizes = coll_stats['indexSizes'] || {}

      unused = stats.select { |s| s['accesses']['ops'] == 0 }
                    .reject { |s| s['name'] == '_id_' } # never drop _id

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
end
