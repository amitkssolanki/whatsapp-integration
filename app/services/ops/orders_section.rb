module Ops
  # Orders created in the period: how clean they arrived, why they were
  # flagged, and how long operators took to decide.
  class OrdersSection
    def initialize(period)
      @scope = Order.where(created_at: period)
    end

    def call
      {
        total: @scope.count,
        review: Stats.zero_filled(Order.review_statuses.keys, @scope.group(:review_status).count),
        by_status: Stats.zero_filled(Order.statuses.keys, @scope.group(:status).count),
        issue_codes: issue_codes,
        decision_minutes: decision_minutes
      }
    end

    private

    # Issues counted per code (an order with two unknown SKUs counts twice).
    def issue_codes
      @scope.pluck(:validation_issues)
            .flat_map { |issues| Array(issues) }
            .filter_map { |issue| issue["code"].to_s.presence if issue.is_a?(Hash) }
            .tally
    end

    # Minutes from the order arriving to an operator deciding it.
    def decision_minutes
      pairs = @scope.where.not(decided_at: nil).pluck(:created_at, :decided_at)
      Stats.summary(Stats.seconds_between(pairs).map { |seconds| seconds / 60.0 })
    end
  end
end
