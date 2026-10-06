module Ops
  # Out-of-order status arrivals are not stored as such, so this reports what
  # the timestamps still show: a read receipt older than the delivery receipt,
  # and a delivery with no `sent` step recorded (a skipped step).
  class StatusAnomaliesSection
    def initialize(period, real: false)
      @scope = Scopes.outbound(period, real: real)
    end

    def call
      {
        read_before_delivered: @scope.where("messages.read_at < messages.delivered_at").count,
        delivered_without_sent: @scope.where.not(delivered_at: nil).where(sent_at: nil).count
      }
    end
  end
end
