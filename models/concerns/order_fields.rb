module OrderFields
  extend ActiveSupport::Concern

  included do
    attr_accessor :prevent_refund, :cohost

    field :value, type: Float
    field :original_description, type: String
    field :percentage_discount, type: Integer
    field :percentage_discount_monthly_donor, type: Integer
    field :session_id, type: String
    field :payment_intent, type: String
    field :transfer_id, type: String
    field :coinbase_checkout_id, type: String
    field :evm_secret, type: String
    field :evm_value, type: BigDecimal
    field :oc_secret, type: String
    field :payment_completed, type: Mongoid::Boolean
    field :application_fee_amount, type: Float
    field :currency, type: String
    field :opt_in_organisation, type: Mongoid::Boolean
    field :opt_in_facilitator, type: Mongoid::Boolean
    field :credit_applied, type: Float
    field :fixed_discount_applied, type: Float
    field :organisation_revenue_share, type: Float
    field :hear_about, type: String
    field :http_referrer, type: String
    field :message_ids, type: String
    field :answers, type: Array
    field :transferred, type: Mongoid::Boolean
    index({ transferred: 1 })

    field :gc_plan_id, type: String
    field :gc_given_name, type: String
    field :gc_family_name, type: String
    field :gc_address_line1, type: String
    field :gc_city, type: String
    field :gc_postal_code, type: String
    field :gc_branch_code, type: String
    field :gc_account_number, type: String
    field :gc_success, type: Mongoid::Boolean
  end

  class_methods do
    def admin_fields
      {
        value: :number,
        currency: :text,
        credit_applied: :number,
        percentage_discount: :number,
        percentage_discount_monthly_donor: :number,
        application_fee_amount: :number,
        organisation_revenue_share: :number,
        http_referrer: :text,
        session_id: :text,
        payment_intent: :text,
        transfer_id: :text,
        coinbase_checkout_id: :text,
        evm_secret: :text,
        evm_value: :number,
        oc_secret: :text,
        payment_completed: :check_box,
        opt_in_organisation: :check_box,
        opt_in_facilitator: :check_box,
        message_ids: :text_area,
        answers: { type: :text_area, disabled: true },
        event_id: :lookup,
        account_id: :lookup,
        discount_code_id: :lookup,
        original_description: :text_area,
        gc_plan_id: :text,
        gc_given_name: :text,
        gc_family_name: :text,
        gc_address_line1: :text,
        gc_city: :text,
        gc_postal_code: :text,
        gc_branch_code: :text,
        gc_account_number: :text,
        gc_success: :check_box,
        tickets: :collection,
        donations: :collection
      }
    end
  end

  def metadata
    order = self
    {
      de_event_id: event.id,
      de_order_id: order.id,
      de_account_id: order.account_id,
      de_donation_revenue: order.donation_revenue,
      de_ticket_revenue: order.ticket_revenue,
      de_discounted_ticket_revenue: order.discounted_ticket_revenue,
      de_percentage_discount: order.percentage_discount,
      de_percentage_discount_monthly_donor: order.percentage_discount_monthly_donor,
      de_credit_applied: order.credit_applied,
      de_fixed_discount_applied: order.fixed_discount_applied
    }
  end
end
