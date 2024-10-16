module MaxMindDownloader
  def self.download
    uri = URI.parse('https://download.maxmind.com/geoip/databases/GeoLite2-City/download?suffix=tar.gz')
    request = Net::HTTP::Get.new(uri)
    request.basic_auth(ENV['MAXMIND_USER_ID'], ENV['MAXMIND_LICENSE_KEY'])

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(request)
    end

    location = response['location']
    redirect_uri = URI.parse(location)
    redirect_response = Net::HTTP.get_response(redirect_uri)

    File.write('geolite2-city.tar.gz', redirect_response.body)
    `tar -xzf geolite2-city.tar.gz`
    `mv GeoLite2-City_*/GeoLite2-City.mmdb .`
    `rm -rf GeoLite2-City_* geolite2-city.tar.gz`
  end
end
