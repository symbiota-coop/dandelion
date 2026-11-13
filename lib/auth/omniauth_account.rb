module OmniAuth
  module Strategies
    class Account
      include OmniAuth::Strategy

      option :sign_in, '/accounts/sign_in'

      def request_phase
        redirect options.sign_in
      end

      def callback_phase
        return fail!(:invalid_request) unless request.post?

        if account
          super
        elsif (paused = ::Account.find_by(email: request.params['email'].to_s.downcase.strip)) && paused.password_sign_in_paused?
          # For the failure page to say when they can next try
          session['sign_in_paused_until'] = paused.password_sign_in_paused_until.to_i
          fail!(:sign_in_paused)
        else
          fail!(:invalid_credentials)
        end
      end

      uid { account.uid }
      info { account.info }

      def account
        @account ||= ::Account.authenticate(request.params['email'], request.params['password'])
      end
    end
  end
end
