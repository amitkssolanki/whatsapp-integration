module Ops
  # How long Meta took between lifecycle steps, in seconds, for outbound
  # messages created in the period that reached both steps. Medians only.
  class LatencySection
    STEPS = {
      accepted_to_sent: %i[accepted_at sent_at],
      sent_to_delivered: %i[sent_at delivered_at],
      delivered_to_read: %i[delivered_at read_at],
      accepted_to_delivered: %i[accepted_at delivered_at]
    }.freeze

    def initialize(period)
      @scope = Message.outbound.where(created_at: period)
    end

    def call
      STEPS.transform_values do |(from, to)|
        Stats.summary(Stats.seconds_between(@scope.where.not(from => nil, to => nil).pluck(from, to)))
      end
    end
  end
end
