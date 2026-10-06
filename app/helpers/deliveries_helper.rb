module DeliveriesHelper
  DELIVERY_TONES = {
    "received" => "info", "processing" => "info", "processed" => "ok",
    "partially_failed" => "warn", "failed" => "bad", "ignored" => "neutral", "unparseable" => "bad"
  }.freeze
  RESULT_TONES = { "applied" => "ok", "duplicate" => "neutral", "ignored" => "neutral", "orphan" => "warn", "anomaly" => "warn", "error" => "bad" }.freeze

  def delivery_status_badge(delivery)
    badge(delivery.status.tr("_", " "), DELIVERY_TONES.fetch(delivery.status, "neutral"))
  end

  def result_badge(result)
    badge(result.to_s, RESULT_TONES.fetch(result.to_s, "neutral"))
  end

  # {"applied"=>2, "orphan"=>1} -> "applied 2 · orphan 1"
  def outcome_summary(delivery)
    summary = delivery.outcome.is_a?(Hash) ? delivery.outcome["summary"] : nil
    return "—" if summary.blank?

    summary.sort.map { |result, count| "#{result} #{count}" }.join(" · ")
  end

  def item_counts_text(delivery)
    counts = delivery.item_counts
    return "—" if counts.blank?

    counts.map { |kind, count| "#{count} #{kind}" }.join(", ")
  end
end
