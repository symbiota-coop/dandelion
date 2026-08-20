module OrganisationEvm
  extend ActiveSupport::Concern

  def check_evm_account
    evm_transactions.each do |token, amount|
      @order = orders.find_by(payment_completed: false, currency: token, evm_value: amount)
      @order ||= orders.deleted.find_by(payment_completed: false, currency: token, evm_value: amount)
      next unless @order

      @order.complete_or_restore(error_context: { order_id: @order.id.to_s })
    end
  end
end
