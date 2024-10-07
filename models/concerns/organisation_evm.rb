module OrganisationEvm
  extend ActiveSupport::Concern

  def evm_transactions
    Organisation.evm_transactions(evm_address)
  end

  def check_evm_account
    evm_transactions.each do |token, amount|
      if (@order = Order.find_by(:payment_completed.ne => true, :currency => token, :evm_value => amount))
        @order.payment_completed!
        @order.send_tickets
        @order.create_order_notification
      elsif (@order = Order.deleted.find_by(:payment_completed.ne => true, :currency => token, :evm_value => amount))
        begin
          @order.restore_and_complete
          # raise Order::Restored
        rescue StandardError => e
          Airbrake.notify(e, order: @order)
        end
      end
    end
  end
end
