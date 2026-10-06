require "open3"

module Ops
  # An operations report for a time period, computed only from the database.
  #
  #   Ops::Report.new(from: 1.day.ago, to: Time.current).call  # => Hash
  #
  # Records are in the period when created (received, for webhook deliveries)
  # in [from, to). Every metric is a count or a duration aggregate: no phone
  # numbers, names, Meta ids or message bodies ever enter the result, and zeros
  # are reported as zeros. The Hash is JSON-serializable.
  class Report
    attr_reader :from, :to

    def initialize(from:, to:)
      @from = coerce(from)
      @to = coerce(to)
      raise ArgumentError, "from must be before to" unless @from < @to
    end

    def call
      period = from...to
      {
        period: { from: from.iso8601, to: to.iso8601, generated_at: Time.current.iso8601, git_sha: git_sha },
        deliveries: DeliveriesSection.new(period).call,
        orders: OrdersSection.new(period).call,
        outbound: OutboundSection.new(period, at: to).call,
        latency: LatencySection.new(period).call,
        status_anomalies: StatusAnomaliesSection.new(period).call,
        window: WindowSection.new(period).call
      }
    end

    private

    def coerce(value)
      time = value.is_a?(String) ? Time.zone.parse(value) : value.in_time_zone
      raise ArgumentError, "not a time: #{value.inspect}" unless time

      time
    end

    def git_sha
      ENV["GIT_SHA"].presence || Open3.capture3("git", "rev-parse", "--short", "HEAD", chdir: Rails.root.to_s).then do |out, _err, status|
        status.success? && out.strip.present? ? out.strip : "unknown"
      end
    rescue StandardError
      "unknown"
    end
  end
end
