class GatheringPaymentMethod
  module Evm
    def self.call(gathering:, membership:, _account:, params:)
      evm_secret = Array.new(4) { [*'1'..'9'].sample }.join
      payment = membership.payments.create!(
        amount: params[:amount].to_i,
        currency: gathering.currency,
        evm_secret: evm_secret
      )
      {
        evm_secret: payment.evm_secret,
        value: payment.evm_amount,
        wei: (payment.evm_amount * 1e18.to_d).to_i,
        payment_id: payment.id.to_s,
        payment_expiry: (payment.created_at + 1.hour).to_datetime.strftime('%Q')
      }.to_json
    end
  end
end
