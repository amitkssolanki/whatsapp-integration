module Ops
  # Webhook deliveries received in the period: what arrived, what became of the
  # items inside, how many were repeats and how many were replayed.
  class DeliveriesSection
    RESULTS = %w[applied duplicate orphan anomaly ignored error].freeze
    KINDS = %w[message status].freeze

    def initialize(period)
      @scope = WebhookDelivery.where(received_at: period)
    end

    def call
      outcomes = @scope.pluck(:outcome)
      items = outcomes.flat_map { |outcome| outcome.is_a?(Hash) ? Array(outcome["items"]) : [] }

      {
        total: @scope.count,
        by_status: Stats.zero_filled(WebhookDelivery.statuses.keys, @scope.group(:status).count),
        exact_duplicate_bodies: duplicate_bodies,
        item_outcomes: item_outcomes(outcomes),
        items_by_kind: Stats.zero_filled(KINDS, items.filter_map { |item| item["kind"] if item.is_a?(Hash) }.tally),
        replays: { total: @scope.sum(:replay_count), deliveries_replayed: @scope.where(replay_count: 1..).count }
      }
    end

    private

    # Deliveries whose raw body hash was already stored earlier (any time, not
    # only in the period). "Earlier" is by received_at, then id.
    def duplicate_bodies
      @scope.where(<<~SQL.squish).count
        EXISTS (
          SELECT 1 FROM webhook_deliveries earlier
          WHERE earlier.body_sha256 = webhook_deliveries.body_sha256
            AND (earlier.received_at, earlier.id) < (webhook_deliveries.received_at, webhook_deliveries.id)
        )
      SQL
    end

    # Sum of the per-delivery summaries; results outside the known set land in
    # `other` rather than being dropped.
    def item_outcomes(outcomes)
      totals = Hash.new(0)
      outcomes.each do |outcome|
        summary = outcome.is_a?(Hash) ? outcome["summary"] : nil
        summary.each { |result, count| totals[result.to_s] += count.to_i } if summary.is_a?(Hash)
      end
      Stats.zero_filled(RESULTS, totals.slice(*RESULTS)).merge("other" => totals.except(*RESULTS).values.sum)
    end
  end
end
