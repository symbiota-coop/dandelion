namespace :atproto do
  desc 'Generate a new ES256 keypair for AT Protocol OAuth'
  task :generate_keys do
    require 'openssl'
    require 'base64'

    key = OpenSSL::PKey::EC.generate('prime256v1')
    pem = key.to_pem

    puts 'Generated new ES256 keypair for AT Protocol OAuth'
    puts ''
    puts 'Add this to your environment variables:'
    puts ''
    puts 'ATPROTO_PRIVATE_KEY_PEM='
    puts pem.gsub("\n", '\\n')
    puts ''
    puts 'Or as a multi-line value (for .env files that support it):'
    puts ''
    puts 'ATPROTO_PRIVATE_KEY_PEM="' + pem.chomp + '"'
  end

  desc 'Display current client metadata JSON'
  task :client_metadata do
    require_relative '../lib/atproto_key_manager'
    require 'json'
    puts JSON.pretty_generate(AtprotoKeyManager.client_metadata)
  end

  desc 'Sync events to AT Protocol (catch-up after downtime). Usage: rake atproto:sync_events[24] for last 24 hours'
  task :sync_events, [:hours] => :environment do |_t, args|
    hours = (args[:hours] || 24).to_i
    dry_run = ENV['DRY_RUN'] == 'true'

    puts "🔄 Syncing events from the last #{hours} hours to AT Protocol#{' (DRY RUN)' if dry_run}..."
    puts ''

    results = Event.sync_atproto(hours: hours, dry_run: dry_run)

    puts '📊 Results:'
    puts "   ✅ Published: #{results[:published]}"
    puts "   🔄 Updated:   #{results[:updated]}"
    puts "   🗑️  Deleted:   #{results[:deleted]}"
    puts "   ⏭️  Skipped:   #{results[:skipped]}"

    if results[:errors].any?
      puts "   ❌ Errors:    #{results[:errors].count}"
      puts ''
      puts '🚨 Error details:'
      results[:errors].each do |error|
        puts "   Event #{error[:event_id]}: #{error[:error]}"
      end
    end

    puts ''
    puts dry_run ? '👆 This was a dry run. Run without DRY_RUN=true to apply changes.' : '✨ Done!'
  end
end
