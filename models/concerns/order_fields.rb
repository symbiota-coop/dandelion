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
    field :gocardless_billing_request_id, type: String
    field :evm_secret, type: String
    field :evm_value, type: BigDecimal
    field :oc_secret, type: String
    field :payment_completed, type: Mongoid::Boolean
    field :application_fee_amount, type: Float
    field :application_fee_paid_to_dandelion, type: Mongoid::Boolean
    field :currency, type: String
    field :opt_in_organisation, type: Mongoid::Boolean
    field :opt_in_facilitator, type: Mongoid::Boolean
    field :credit_applied, type: Float
    field :fixed_discount_applied, type: Float
    field :organisation_revenue_share, type: Float
    field :hear_about, type: String
    field :via, type: String
    field :http_referrer, type: String
    field :message_ids, type: String
    field :answers, type: Array
    field :transferred, type: Mongoid::Boolean
    field :restored, type: Mongoid::Boolean

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
        application_fee_paid_to_dandelion: :check_box,
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
    metadata_hash = {
      de_event_id: event.id,
      de_order_id: order.id,
      de_account_id: order.account_id,
      de_account_name: order.account.name,
      de_account_email: order.account.email,
      de_donation_revenue: order.donation_revenue,
      de_donation_to_dandelion: order.application_fee_paid_to_dandelion,
      de_ticket_revenue: order.ticket_revenue,
      de_discounted_ticket_revenue: order.discounted_ticket_revenue,
      de_percentage_discount: order.percentage_discount,
      de_percentage_discount_monthly_donor: order.percentage_discount_monthly_donor,
      de_credit_applied: order.credit_applied,
      de_fixed_discount_applied: order.fixed_discount_applied
    }

    # Include event question answers if configured
    if event&.organisation&.event_questions_to_include_in_metadata.present? && order.answers.present?
      questions_to_include = event.organisation.event_questions_to_include_in_metadata

      order.answers.each do |question, answer|
        next unless question && answer && questions_to_include.include?(question)

        # Extract question text (remove formatting like <options>, [options], etc.)
        question_text = question.dup
        [
          Order::SELECT_FIELD_REGEX,
          Order::MULTIPLE_CHECKBOX_FIELD_REGEX,
          Order::CHECKBOX_FIELD_REGEX,
          Order::DATE_FIELD_REGEX
        ].each do |regex|
          if (match = question_text.match(regex))
            question_text = match[1]
            break
          end
        end
        question_text = question_text.gsub(/^#\s*/, '') # Remove markdown headers
        question_text = question_text.strip.chomp('*') # Remove trailing asterisk if required

        # Parameterize the question text for use as metadata key
        # Truncate by word count to avoid cutting words in half
        parameterized = question_text.parameterize(separator: '_')
        words = parameterized.split('_')
        parameterized = words.first(5).join('_') if words.length > 5

        # Format answer for metadata (handle arrays for multiple checkboxes)
        answer_value = answer.is_a?(Array) ? answer.join(', ') : answer.to_s

        metadata_hash[:"de_question_#{parameterized}"] = answer_value
      end
    end

    metadata_hash
  end
end
