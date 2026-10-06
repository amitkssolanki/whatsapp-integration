module Ops
  # Messages customers sent in the period, and how many different customers
  # that was. Customers known only by business-scoped user id (Meta omitted
  # their phone number) are counted but never identified.
  class InboundSection
    def initialize(period, real: false)
      @scope = Scopes.inbound(period, real: real)
    end

    def call
      customers = Customer.where(id: Conversation.where(id: @scope.select(:conversation_id)).select(:customer_id))
      {
        messages: @scope.count,
        by_type: Stats.tally(@scope.pluck(:message_type), blank: "unknown"),
        distinct_customers: customers.count,
        # A purged customer's number is gone; `purged_had_phone` remembers the answer.
        customers_without_phone: customers.where(whatsapp_number: [ nil, "" ]).where("customers.purged_had_phone IS NOT TRUE").count
      }
    end
  end
end
