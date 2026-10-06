module Ops
  # Messages customers sent in the period, and how many different customers
  # that was. Customers known only by business-scoped user id (Meta omitted
  # their phone number) are counted but never identified.
  class InboundSection
    def initialize(period)
      @scope = Message.inbound.where(created_at: period)
    end

    def call
      customers = Customer.where(id: Conversation.where(id: @scope.select(:conversation_id)).select(:customer_id))
      {
        messages: @scope.count,
        by_type: Stats.tally(@scope.pluck(:message_type), blank: "unknown"),
        distinct_customers: customers.count,
        customers_without_phone: customers.where(whatsapp_number: [ nil, "" ]).count
      }
    end
  end
end
