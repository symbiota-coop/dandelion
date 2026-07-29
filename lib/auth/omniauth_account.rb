module OmniAuth
  module Strategies
    class Account
      include OmniAuth::Strategy

      option :sign_in, '/accounts/sign_in'

      def request_phase
        redirect options.sign_in
      end

      def callback_phase
        if account
          super
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
