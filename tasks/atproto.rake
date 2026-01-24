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
end
