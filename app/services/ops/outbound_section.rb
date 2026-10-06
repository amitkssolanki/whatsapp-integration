module Ops
  # Outbound messages created in the period: purposes, current states, why
  # sends failed, how often they were retried, and what is still unconfirmed.
  class OutboundSection
    # Same threshold as Message.undelivered.
    UNDELIVERED_AFTER = 10.minutes

    def initialize(period, at:)
      @scope = Message.outbound.where(created_at: period)
      @at = at
    end

    def call
      {
        total: @scope.count,
        by_purpose: Stats.tally(@scope.pluck(:purpose)),
        by_status: Stats.zero_filled(Message.statuses.keys - %w[received], @scope.group(:status).count),
        failed_by_error_category: Stats.tally(@scope.failed.pluck(:error_category), blank: "uncategorised"),
        error_codes: @scope.where.not(error_code: nil).group(:error_code).count.transform_keys(&:to_s),
        attempts: { total: @scope.sum(:attempts), messages_retried: @scope.where(attempts: 2..).count },
        unknown: unknown,
        blocked: @scope.blocked.count,
        guard_overrides: @scope.where.not(guard_override_by: [ nil, "" ]).count,
        undelivered: @scope.where(status: %w[accepted sent], delivered_at: nil).where(accepted_at: ...(@at - UNDELIVERED_AFTER)).count
      }
    end

    private

    # Messages currently `unknown` (the send's outcome is not known) and how
    # many of those already carry a later status timestamp from Meta.
    def unknown
      scope = @scope.unknown
      {
        count: scope.count,
        with_sent_at: scope.where.not(sent_at: nil).count,
        with_delivered_at: scope.where.not(delivered_at: nil).count,
        with_read_at: scope.where.not(read_at: nil).count
      }
    end
  end
end
