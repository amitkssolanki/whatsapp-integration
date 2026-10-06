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

      message = find_by_wa_message_id(wa_message_id)
      unless message
        message, stale = find_by_opaque_id(wa_message_id)
        return result(wa_message_id, "orphan", "stale id after resend") if stale
      end
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

    def find_by_wa_message_id(wa_message_id)
      Message.outbound.find_by(wa_message_id: wa_message_id) if wa_message_id.present?
    end

    # Fallback after Meta's id missed: the id we asked Meta to echo. A message
    # whose send was never recorded (a crash between the HTTP response and our
    # write) has no wa_message_id yet; it is found this way and gets its
    # wa_message_id on first contact.
    #
    # The opaque id names the message, not the attempt, so it is trusted ONLY
    # while the message has no wa_message_id of its own. One that already holds
    # a different id has been (re)sent since: this status belongs to an earlier
    # attempt (e.g. a replayed or redelivered webhook after an operator resend)
    # and must not touch the current one. A `pending` message has no attempt in
    # flight at all (an operator resend wipes the id and the evidence), so a
    # status cannot belong to it either.
    #
    # Returns [message, stale]; stale is true when a message matched but was
    # refused.
    def find_by_opaque_id(wa_message_id)
      opaque = @item["biz_opaque_callback_data"].to_s
      return [ nil, false ] unless opaque.match?(/\A\d+\z/)

      message = Message.outbound.find_by(id: opaque.to_i)
      return [ nil, false ] unless message
      return [ nil, true ] if message.wa_message_id.present? || message.pending?

      if wa_message_id.present?
        Message.where(id: message.id, wa_message_id: nil).update_all(wa_message_id: wa_message_id)
        message.reload
      end
      [ message, false ]
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
