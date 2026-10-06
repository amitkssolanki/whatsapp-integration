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
  #
  # Every section is computed twice:
  #
  #   real      only rows that show real platform behaviour: no fault was
  #             injected on them (`injected_faults` empty; this includes
  #             re-posted deliveries) and, for outbound messages, they do not
  #             belong to simulated "Demo Customer" customers.
  #   all       every row, injected and simulated ones included.
  #
  # `injected` summarises what was labeled, by label. Latency comes from real
  # rows only, so `all[:latency]` is the same as `real[:latency]`. Sections
  # with no injected or simulated rows (orders, catalog, inbound) are the same
  # in both.
  #
  # Quote `real` for what the platform did; use `all` to reconcile counts with
  # the database.
  class Report
    attr_reader :from, :to

    def initialize(from:, to:)
      @from = coerce(from)
      @to = coerce(to)
      raise ArgumentError, "from must be before to" unless @from < @to
    end

    def call
      period = from...to
      shared = {
        orders: OrdersSection.new(period).call,
        latency: LatencySection.new(period).call,
        catalog: CatalogSection.new(period).call,
        inbound: InboundSection.new(period).call
      }
      {
        period: { from: from.iso8601, to: to.iso8601, generated_at: Time.current.iso8601, git_sha: git_sha },
        real: sections(period, real: true, **shared),
        all: sections(period, real: false, **shared),
        injected: InjectedSection.new(period).call
      }
    end

    # A compact human-readable summary (tables) of the same numbers; pass an
    # already computed result to avoid querying twice.
    def to_markdown(data = call)
      MarkdownRenderer.new(data).render
    end

    private

    def sections(period, real:, orders:, latency:, catalog:, inbound:)
      {
        deliveries: DeliveriesSection.new(period, real: real).call,
        orders: orders,
        outbound: OutboundSection.new(period, at: to, real: real).call,
        latency: latency,
        status_anomalies: StatusAnomaliesSection.new(period, real: real).call,
        window: WindowSection.new(period, real: real).call,
        catalog: catalog,
        inbound: inbound
      }
    end

    def coerce(value)
      time = value.is_a?(String) ? Time.zone.parse(value) : value.in_time_zone
      raise ArgumentError, "not a time: #{value.inspect}" unless time

      time
    end

    # GIT_SHA if given, else KAMAL_VERSION (Kamal passes it to every app
    # container as `--env KAMAL_VERSION=<git sha>`: kamal 2.12.0
    # lib/kamal/commands/app.rb), else the local checkout, else "unknown": the
    # production image has no git and no .git directory.
    def git_sha
      ENV["GIT_SHA"].presence || ENV["KAMAL_VERSION"].presence || Open3.capture3("git", "rev-parse", "--short", "HEAD", chdir: Rails.root.to_s).then do |out, _err, status|
        status.success? && out.strip.present? ? out.strip : "unknown"
      end
    rescue StandardError
      "unknown"
    end
  end
end
