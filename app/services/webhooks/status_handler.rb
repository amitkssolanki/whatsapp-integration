module Webhooks
  # Applies one status update for an outbound message, inside the caller's
  # transaction. Statuses are the only evidence of what WhatsApp did with a
  # message V1 reported as "sent"; see docs/v2/DESIGN.md §3 and §6.
  class StatusHandler
    LIFECYCLE_STATUSES = %w[sent delivered read].freeze

    def initialize(delivery:, item:)
      @delivery = delivery
      @item = item
    end

    def call
      wa_message_id = @item["id"].to_s
      status = @item["status"].to_s
      return result(wa_message_id, "ignored", "status=#{status.presence || 'missing'}") unless known_status?(status)

      message = find_message(wa_message_id)
      return result(wa_message_id, "orphan", "no outbound message matches") unless message

      status == "failed" ? apply_failure(message, wa_message_id) : apply_lifecycle(message, wa_message_id, status)
    end

    private

    def known_status?(status)
      LIFECYCLE_STATUSES.include?(status) || status == "failed"
    end

    def apply_lifecycle(message, wa_message_id, status)
      changed = message.apply_lifecycle!(status, at: status_time)
      result(wa_message_id, changed ? "applied" : "duplicate", "message_id=#{message.id} status=#{status}")
    end

    def apply_failure(message, wa_message_id)
      error = Array(@item["errors"]).first
      error = {} unless error.is_a?(Hash)

      outcome = message.apply_failure!(
        at: status_time,
        code: integer_or_nil(error["code"]),
        title: error["title"],
        details: error.dig("error_data", "details").presence || error["message"]
      )

      case outcome
      when :applied
        message.log_window_disagreement(source: "status_webhook") if message.error_category == "window_closed"
        result(wa_message_id, "applied", "message_id=#{message.id} status=failed")
      when :anomaly then result(wa_message_id, "anomaly", "message_id=#{message.id} failed after #{message.status}")
      when :duplicate then result(wa_message_id, "duplicate", "message_id=#{message.id} status=failed")
      else result(wa_message_id, "ignored", "message_id=#{message.id} is #{message.status}")
      end
    end

    # Meta's id first. A message whose send was never recorded (a crash between
    # the HTTP response and our write) has no wa_message_id yet; it is found by
    # the id we asked Meta to echo, and gets its wa_message_id on first contact.
    def find_message(wa_message_id)
      message = Message.outbound.find_by(wa_message_id: wa_message_id) if wa_message_id.present?
      return message if message

      opaque = @item["biz_opaque_callback_data"].to_s
      return nil unless opaque.match?(/\A\d+\z/)

      message = Message.outbound.find_by(id: opaque.to_i)
      if message && message.wa_message_id.nil? && wa_message_id.present?
        Message.where(id: message.id, wa_message_id: nil).update_all(wa_message_id: wa_message_id)
        message.reload
      end
      message
    end

    def status_time
      stamp = @item["timestamp"].to_s
      stamp.match?(/\A\d+\z/) ? Time.at(stamp.to_i).utc : Time.current
    end

    def integer_or_nil(value)
      Integer(value.to_s, exception: false)
    end

    def result(ref, outcome, detail)
      ItemResult.for("status", ref, outcome, detail)
    end
  end
end
