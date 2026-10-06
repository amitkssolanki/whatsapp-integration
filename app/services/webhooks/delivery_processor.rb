module Webhooks
  # Runs every message and status inside a stored delivery, one transaction
  # per item, and returns the outcome to record. Item failures are contained:
  # that item rolls back and is reported as `error`, the rest still apply.
  #
  # Infrastructure errors (database connectivity, deadlocks) are the exception:
  # they propagate so the job retries the whole delivery, which is safe
  # because applied items are idempotent.
  class DeliveryProcessor
    # Passed to `rescue` and `retry_on`; see Webhooks::InfrastructureError for
    # the classes and where they come from.
    INFRASTRUCTURE_ERRORS = [ Webhooks::InfrastructureError ].freeze

    Outcome = Data.define(:results) do
      def summary = results.map(&:result).tally

      def errors = results.count { |result| result.result == "error" }

      def first_error = results.find { |result| result.result == "error" }

      def to_h
        { "items" => results.map(&:to_outcome), "summary" => summary }.tap do |hash|
          hash["reason"] = "no_items" if results.empty?
        end
      end
    end

    FOREIGN_NUMBER = "phone_number_mismatch".freeze

    def initialize(delivery, config: Rails.application.config.whatsapp)
      @delivery = delivery
      @config = config
    end

    def call
      payload = Webhooks::Payload.parse(@delivery.raw_body) or raise ArgumentError, "stored body is not JSON"

      results = []
      payload.each_item { |kind, value, item| results << process_item(kind, value, item) }
      Outcome.new(results: results)
    end

    private

    def process_item(kind, value, item)
      # One POST can carry changes for several business numbers; each item is
      # judged by its own change's metadata.
      return foreign_result(kind, item) if Webhooks::Payload.foreign?(value, @config.phone_number_id)

      ActiveRecord::Base.transaction do
        handler = kind == "message" ? MessageHandler.new(delivery: @delivery, value: value, item: item) : StatusHandler.new(delivery: @delivery, item: item)
        handler.call
      end.tap { |result| log_item(result) }
    rescue *INFRASTRUCTURE_ERRORS
      raise
    rescue StandardError => e
      AppLog.event("webhook.item_failed", delivery_id: @delivery.id, kind: kind, error_class: e.class.name)
      ItemResult.for(kind, item["id"].to_s, "error", Redact.exception(e))
    end

    def foreign_result(kind, item)
      ItemResult.for(kind, item["id"].to_s, "ignored", FOREIGN_NUMBER).tap { |result| log_item(result) }
    end

    def log_item(result)
      AppLog.event("webhook.item", delivery_id: @delivery.id, kind: result.kind, result: result.result)
    end
  end
end
