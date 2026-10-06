module Ops
  # Which rows count as "real platform behaviour" in the report. Injected rows
  # (a fault toggle fired, a captured body was re-posted: `injected_faults`
  # is not empty) and simulated ones (customers named "Demo Customer N" by
  # demo:simulate) show what the app does, not what Meta does, so they stay out
  # of the `real` numbers and are only counted in `all` and in `injected`.
  module Scopes
    DEMO_CUSTOMER_PREFIX = "Demo Customer".freeze

    module_function

    def deliveries(period, real:)
      scope = WebhookDelivery.where(received_at: period)
      real ? scope.where("cardinality(webhook_deliveries.injected_faults) = 0") : scope
    end

    def outbound(period, real:)
      scope = Message.outbound.where(created_at: period)
      return scope unless real

      scope.where("cardinality(messages.injected_faults) = 0").where.not(conversation_id: demo_conversations)
    end

    def demo_conversations
      demo_customers = Customer.where("customers.display_name LIKE ?", "#{DEMO_CUSTOMER_PREFIX}%").select(:id)
      Conversation.where(customer_id: demo_customers).select(:id)
    end
  end
end
