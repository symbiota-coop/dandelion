module OrganisationEvm
  extend ActiveSupport::Concern

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
          Honeybadger.context({ order_id: @order.id })
          Honeybadger.notify(e)
        end
      end
    end
  end
end
