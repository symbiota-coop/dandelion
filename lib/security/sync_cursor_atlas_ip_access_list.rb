module SyncCursorAtlasIpAccessList
  COMMENT = 'Cursor Cloud Agent (auto-synced)'

  def self.run(apply: false)
    public_key = ENV['ATLAS_PUBLIC_KEY']
    private_key = ENV['ATLAS_PRIVATE_KEY']
    group_id = ENV['ATLAS_GROUP_ID']

    ips = JSON.parse(Net::HTTP.get(URI('https://cursor.com/docs/ips.json')))
              .fetch('cloudAgents').values.flatten.uniq
    desired = ips.map { |ip| "#{ip.split('.').first}.0.0.0/8" }.uniq.sort

    managed = atlas(public_key, private_key, 'GET', "/api/atlas/v2/groups/#{group_id}/accessList")
              .fetch('results', [])
              .select { |entry| entry['comment'] == COMMENT }
              .map { |entry| entry['cidrBlock'] || entry['ipAddress'] }

    to_add = desired - managed
    to_remove = managed - desired

    puts "Add #{to_add.size}, remove #{to_remove.size}"
    return if to_add.empty? && to_remove.empty?

    unless apply
      puts 'Dry run only. Pass apply: true to update Atlas.'
      return
    end

    to_remove.each do |cidr|
      encoded = URI.encode_www_form_component(cidr)
      atlas(public_key, private_key, 'DELETE', "/api/atlas/v2/groups/#{group_id}/accessList/#{encoded}")
    end

    to_add.each_slice(25) do |batch|
      body = batch.map { |cidr| { cidrBlock: cidr, comment: COMMENT } }
      atlas(public_key, private_key, 'POST', "/api/atlas/v2/groups/#{group_id}/accessList", body)
    end
  end

  def self.atlas(public_key, private_key, method, path, body = nil)
    cmd = [
      'curl', '--silent', '--show-error', '--fail',
      '--digest', '-u', "#{public_key}:#{private_key}",
      '-H', 'Accept: application/vnd.atlas.2023-01-01+json',
      '-X', method, "https://cloud.mongodb.com#{path}"
    ]
    cmd.insert(-2, '-H', 'Content-Type: application/vnd.atlas.2023-01-01+json', '-d', JSON.generate(body)) if body

    stdout, stderr, status = Open3.capture3(*cmd)
    raise "Atlas API failed: #{stderr.empty? ? stdout : stderr}" unless status.success?

    stdout.empty? ? {} : JSON.parse(stdout)
  end

  private_class_method :atlas
end
