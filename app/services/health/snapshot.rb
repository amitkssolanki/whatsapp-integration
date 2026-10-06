module Health
  # Everything the operator's Health page needs, as plain SQL and plain data. It
  # only reads. `call` returns a Hash of counts plus short "recent" lists of
  # records (newest first, at most RECENT_LIMIT each):
  #
  #   deliveries:   counts + recent for failed, partially_failed (all time: they stay
  #                 actionable until replayed), unparseable and ignored (last `window`)
  #   outbound:     by_status, failed_by_category, unknown, undelivered, blocked, retry_scheduled
  #   orders:       needs_review (undecided orders flagged by validation)
  #   anomalies:    deliveries in the last `window` whose outcome has orphan or anomaly items
  #   queue:        Solid Queue failed executions
  #   fault_injection: toggles that are active (and any that are set but ignored), see FaultInjection
  #   config_banner: active when every failure in the last hour is an auth_config/account_config one
  #
  # Rejected signatures cannot be counted from the database (rejected requests are
  # not stored), so they are not here.
  class Snapshot
    RECENT_LIMIT = 10
    CONFIG_CATEGORIES = %w[auth_config account_config].freeze
    CONFIG_WINDOW = 1.hour

    def initialize(window: 7.days, now: Time.current)
      @window = window
      @now = now
    end

    def call
      {
        generated_at: @now,
        deliveries: deliveries,
        outbound: outbound,
        orders: { needs_review: listing(Order.received.needs_review.order(id: :desc)) },
        anomalies: anomalies,
        queue: { failed_executions: failed_executions },
        config_banner: config_banner,
        fault_injection: { active: FaultInjection.active, ignored: FaultInjection.ignored }
      }
    end

    private

    def deliveries
      since = @now - @window
      {
        failed: listing(WebhookDelivery.failed.order(received_at: :desc)),
        partially_failed: listing(WebhookDelivery.partially_failed.order(received_at: :desc)),
        unparseable: listing(WebhookDelivery.unparseable.where(received_at: since..).order(received_at: :desc)),
        ignored: listing(WebhookDelivery.ignored.where(received_at: since..).order(received_at: :desc))
      }
    end

    def outbound
      messages = Message.outbound
      {
        by_status: Message.statuses.except("received").keys.index_with(0).merge(messages.group(:status).count),
        failed_by_category: messages.failed.group(:error_category).count.transform_keys { |category| category || "uncategorised" },
        failed: listing(messages.failed.order(failed_at: :desc, id: :desc)),
        unknown: listing(messages.unknown.order(updated_at: :desc)),
        undelivered: listing(Message.undelivered.order(:accepted_at)),
        blocked: listing(messages.blocked.order(blocked_at: :desc)),
        retry_scheduled: listing(messages.retry_scheduled.order(:next_attempt_at))
      }
    end

    # Orphan statuses and anomalies are recorded per item in the delivery's
    # outcome summary ({"applied"=>1, "orphan"=>2, ...}).
    def anomalies
      scope = WebhookDelivery.where(received_at: (@now - @window)..)
      flagged = scope.where("COALESCE((outcome->'summary'->>'orphan')::int, 0) + COALESCE((outcome->'summary'->>'anomaly')::int, 0) > 0")
      totals = flagged.pick(
        Arel.sql("COALESCE(SUM((outcome->'summary'->>'orphan')::int), 0)"),
        Arel.sql("COALESCE(SUM((outcome->'summary'->>'anomaly')::int), 0)")
      )

      {
        orphan_items: totals[0].to_i,
        anomaly_items: totals[1].to_i,
        deliveries: listing(flagged.order(received_at: :desc))
      }
    end

    def failed_executions
      SolidQueue::FailedExecution.count
    end

    # "Fix your configuration" is the most useful thing to tell an operator when
    # sends keep failing for token or account reasons. It clears itself when a
    # message has been accepted since the latest failure, or the failures age out.
    def config_banner
      recent = Message.outbound.failed.where(failed_at: (@now - CONFIG_WINDOW)..)
      latest = recent.order(failed_at: :desc, id: :desc).first
      return inactive unless latest

      categories = recent.distinct.pluck(:error_category)
      return inactive unless categories.all? { |category| CONFIG_CATEGORIES.include?(category) }
      return inactive if Message.outbound.where(accepted_at: latest.failed_at..).exists?

      {
        active: true,
        categories: categories.sort,
        failures: recent.count,
        latest_failed_at: latest.failed_at,
        latest_error_code: latest.error_code,
        latest_error_title: latest.error_title
      }
    end

    def inactive = { active: false, categories: [], failures: 0, latest_failed_at: nil, latest_error_code: nil, latest_error_title: nil }

    def listing(scope)
      { count: scope.count, recent: scope.limit(RECENT_LIMIT).to_a }
    end
  end
end
