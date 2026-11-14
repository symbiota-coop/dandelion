# Recaptcha for the routes that check it (signing up, joining or applying to a gathering signed out). .env.test has no
# recaptcha settings, so those routes skip it unless a test configures it with with_recaptcha
module RecaptchaHelpers
  # Configures recaptcha with a verifier that always fails, and returns the verify calls made
  def with_recaptcha(skip_secret: nil, &block)
    env = { 'RECAPTCHA_SECRET_KEY' => 'recaptcha-secret', 'RECAPTCHA_VERIFY_URL' => 'https://recaptcha.test/verify', 'RECAPTCHA_SKIP_SECRET' => skip_secret }

    # Real connections (Mailgun uses Faraday too), with only posts to the verify URL intercepted
    verify_url = env['RECAPTCHA_VERIFY_URL']
    verify_calls = []
    verify_response = api_object(body: { success: false }.to_json)
    faraday_new = Faraday.method(:new)
    stubbed_new = lambda do |*args, **kwargs, &block|
      connection = faraday_new.call(*args, **kwargs, &block)
      connection.define_singleton_method(:post) do |url = nil, body = nil, headers = nil, &post_block|
        return super(url, body, headers, &post_block) unless url == verify_url

        verify_calls << [url, body]
        verify_response
      end
      connection
    end
    with_env(env) { Faraday.stub(:new, stubbed_new, &block) }
    verify_calls
  end
end
