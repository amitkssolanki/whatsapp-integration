module Ops
  # Which rows count as "real platform behaviour" in the report. Injected rows
  # (a fault toggle fired, a captured body was re-posted: `injected_faults`
  # is not empty) and simulated or synthetic ones show what the app does, not
  # what Meta does, so they stay out of the `real` numbers and are only counted
  # in `all`:
  #
  #   * customers flagged `synthetic` (demo:seed_integration), their messages
  #     and orders, and deliveries flagged `synthetic`
  #   * customers named "Demo Customer N" (demo:simulate)
  module Scopes
    DEMO_CUSTOMER_PREFIX = "Demo Customer".freeze

    module_function

    def deliveries(period, real:)
      scope = WebhookDelivery.where(received_at: period)
      real ? scope.non_synthetic.where("cardinality(webhook_deliveries.injected_faults) = 0") : scope
    end

    def outbound(period, real:)
      scope = Message.outbound.where(created_at: period)
      return scope unless real

      scope.where("cardinality(messages.injected_faults) = 0").where.not(conversation_id: demo_conversations)
    end

    def inbound(period, real:)
      scope = Message.inbound.where(created_at: period)
      real ? scope.where.not(conversation_id: demo_conversations) : scope
    end

    def orders(period, real:)
      scope = Order.where(created_at: period)
      real ? scope.where.not(customer_id: demo_customers) : scope
    end

    # Synthetic (demo:seed_integration) or simulated (demo:simulate) customers.
    def demo_customers
      Customer.where(synthetic: true).or(Customer.where("customers.display_name LIKE ?", "#{DEMO_CUSTOMER_PREFIX}%")).select(:id)
    end

    def demo_conversations
      Conversation.where(customer_id: demo_customers).select(:id)
    end
  end
end
