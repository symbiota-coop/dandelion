class Paypal
  LIVE_HOST = 'https://api-m.paypal.com'
  SANDBOX_HOST = 'https://api-m.sandbox.paypal.com'
  TOKEN_EXPIRY_SKEW = 60

  class RequestError < StandardError
    attr_reader :status, :body

    def initialize(message = nil, status: nil, body: nil)
      @status = status
      @body = body
      super(message)
    end
  end

  class << self
    def host(sandbox:)
      sandbox ? SANDBOX_HOST : LIVE_HOST
    end

    def amount_hash(total, currency)
      cents = (total.to_d * 100).round
      { currency_code: currency, value: format('%.2f', cents / 100.0) }
    end

    def approve_url(order)
      links = order.is_a?(Hash) ? order['links'] : nil
      return unless links

      link = links.find { |l| %w[payer-action approve].include?(l['rel']) }
      link && link['href']
    end

    def capture_id(order)
      order.dig('purchase_units', 0, 'payments', 'captures', 0, 'id')
    end

    def completed?(order)
      return true if order['status'] == 'COMPLETED'

      captures = order.dig('purchase_units', 0, 'payments', 'captures') || []
      captures.any? { |capture| capture['status'] == 'COMPLETED' }
    end

    def approved?(order)
      order['status'] == 'APPROVED'
    end

    def error_message(body, status: nil)
      summary = nil
      details = nil
      if body.is_a?(Hash)
        summary = [body['message'], body['name'], body['error_description'], body['error']].reject(&:blank?).first
        details = Array(body['details']).map { |d| d['description'] || d['issue'] }.compact
        details = details.join('; ') if details.any?
      elsif body.present?
        summary = body.to_s.truncate(200)
      end
      summary ||= 'PayPal request failed'
      message = [summary, details].compact.join(': ')
      message += " (HTTP #{status})" if status
      message
    end

    def token_cache
      @token_cache ||= {}
    end
  end

  def initialize(client_id:, secret:, sandbox: false)
    @client_id = client_id
    @secret = secret
    @sandbox = sandbox
    @host = self.class.host(sandbox: sandbox)
  end

  def create_order(amount:, currency:, description:, return_url:, cancel_url:, custom_id:, brand_name: nil, request_id: nil)
    brand_name = brand_name.to_s.truncate(127)
    brand_name = nil if brand_name.blank?

    post(
      '/v2/checkout/orders',
      {
        intent: 'CAPTURE',
        purchase_units: [{
          amount: self.class.amount_hash(amount, currency),
          description: description.to_s.truncate(127),
          custom_id: custom_id.to_s.truncate(127)
        }],
        payment_source: {
          paypal: {
            experience_context: {
              return_url: return_url,
              cancel_url: cancel_url,
              user_action: 'PAY_NOW',
              shipping_preference: 'NO_SHIPPING',
              brand_name: brand_name
            }.compact
          }
        }
      },
      headers: paypal_headers(request_id)
    )
  end

  def get_order(id)
    get("/v2/checkout/orders/#{id}")
  end

  def capture_order(id, request_id: nil)
    post(
      "/v2/checkout/orders/#{id}/capture",
      {},
      headers: paypal_headers(request_id)
    )
  end

  def refund_capture(capture_id, amount:, currency:)
    post(
      "/v2/payments/captures/#{capture_id}/refund",
      { amount: self.class.amount_hash(amount, currency) }
    )
  end

  private

  def get(path)
    request(:get, path)
  end

  def post(path, body, headers: {})
    request(:post, path, body: body, headers: headers)
  end

  def request(method, path, body: nil, headers: {})
    response = api_connection.public_send(method, path) do |req|
      headers.each { |key, value| req.headers[key] = value }
      req.body = body unless body.nil? || method == :get
    end
    raise_for_status(response)
    response.body
  rescue Faraday::Error => e
    if e.response
      body = e.response_body
      raise RequestError.new(self.class.error_message(body, status: e.response_status), status: e.response_status, body: body)
    end
    raise RequestError.new(e.message, status: e.response_status)
  end

  def raise_for_status(response)
    return if response.success?

    body = response.body
    raise RequestError.new(self.class.error_message(body, status: response.status), status: response.status, body: body)
  end

  def api_connection
    Faraday.new(url: @host) do |f|
      f.options.timeout = 15
      f.options.open_timeout = 5
      f.request :json
      f.response :json
      f.adapter Faraday.default_adapter
    end.tap do |conn|
      conn.headers['Authorization'] = "Bearer #{access_token}"
    end
  end

  def access_token
    cached = token_cache[token_cache_key]
    return cached[:token] if cached && cached[:expires_at] > Time.now

    response = token_connection.post('/v1/oauth2/token') do |req|
      req.headers['Authorization'] = "Basic #{Base64.strict_encode64("#{@client_id}:#{@secret}")}"
      req.body = { grant_type: 'client_credentials' }
    end
    raise_for_status(response)

    token = response.body['access_token']
    expires_in = response.body['expires_in'].to_i
    expires_in = 300 if expires_in <= 0
    token_cache[token_cache_key] = { token: token, expires_at: Time.now + expires_in - TOKEN_EXPIRY_SKEW }
    token
  end

  def token_cache_key
    "#{@host}:#{@client_id}"
  end

  def paypal_headers(request_id)
    headers = { 'Prefer' => 'return=representation' }
    headers['PayPal-Request-Id'] = request_id.to_s if request_id
    headers
  end

  def token_connection
    Faraday.new(url: @host) do |f|
      f.options.timeout = 15
      f.options.open_timeout = 5
      f.request :url_encoded
      f.response :json
      f.adapter Faraday.default_adapter
    end
  end

  def token_cache
    self.class.token_cache
  end
end
