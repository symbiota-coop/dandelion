# Serves iCal feeds and Luma pages to organisation calendar imports without the network
module CalendarImportHelpers
  # responses: { url => { status:, body:, headers: } }, or { url => exception } to raise it instead. Faraday.get (the
  # feed) and connections from Faraday.new (Luma's event pages) both answer from it, failing on any other URL. Each URL
  # requested is pushed to requested_urls. The responses can be given without braces, as keywords
  def stub_faraday(responses = {}, requested_urls: nil, **more_responses)
    responses = responses.merge(more_responses.transform_keys(&:to_s))
    response_class = Struct.new(:status, :body, :headers) do
      def success?
        status.between?(200, 299)
      end
    end

    responder = lambda do |url, *_args|
      url = url.to_s
      requested_urls&.push(url)
      response = responses.fetch(url) { raise "Unexpected Faraday.get for #{url}" }
      raise response if response.is_a?(Exception)

      response_class.new(response[:status], response[:body], response[:headers] || {})
    end

    connection_builder = lambda do |*args, **kwargs, &block|
      Faraday::Connection.new(*args, **kwargs) do |f|
        block&.call(f)
        f.adapter :test do |stub|
          responses.each do |url, spec|
            stub.get(url) do
              requested_urls&.push(url)
              raise spec if spec.is_a?(Exception)

              [spec[:status], spec[:headers] || {}, spec[:body]]
            end
          end
        end
      end
    end

    Faraday.stub(:get, responder) do
      Faraday.stub(:new, connection_builder) { yield }
    end
  end
end
