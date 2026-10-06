module Ops
  # What was labeled as injected in the period (a fault toggle fired, or a
  # captured body was re-posted), by label. The rows themselves are excluded
  # from the `real` sections; this says how much there was. Synthetic and
  # simulated rows are not counted here at all: their faults are scripted.
  class InjectedSection
    def initialize(period)
      @deliveries = WebhookDelivery.non_synthetic.where(received_at: period)
      @messages = Message.outbound.where(created_at: period).where.not(conversation_id: Scopes.demo_conversations)
    end

    def call
      { deliveries: summary(@deliveries), messages: summary(@messages) }
    end

    private

    # Rows with at least one label, and how many times each label occurs.
    def summary(scope)
      labeled = scope.where("cardinality(injected_faults) > 0")
      { total: labeled.count, by_label: labeled.pluck(:injected_faults).flatten.tally.sort.to_h }
    end
  end
end
