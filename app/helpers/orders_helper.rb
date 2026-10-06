module OrdersHelper
  def cents_to_money(cents)
    return "—" if cents.nil?

    number_to_currency(BigDecimal(cents.to_i) / 100)
  end

  def order_status_badge(order)
    badge(order.status, { "received" => "info", "accepted" => "ok", "rejected" => "bad" }.fetch(order.status, "neutral"))
  end

  def review_badge(order)
    order.needs_review? ? badge("needs review", "warn") : tag.span("—", class: "muted")
  end

  # A validation issue ({code, sku, expected, actual}, docs/v2/DESIGN.md §9) in
  # words an operator can act on.
  def issue_text(issue)
    issue = issue.to_h.stringify_keys
    sku = scrub_ids(issue["sku"]).presence
    expected = issue["expected"]
    actual = issue["actual"]

    case issue["code"]
    when "unknown_sku"
      "Unknown product#{" #{sku}" if sku}: it is not in our menu. The line was kept without a product."
    when "price_mismatch"
      "#{sku}: the customer saw #{cents_to_money(actual)} but our price is #{cents_to_money(expected)}. Priced at what the customer saw."
    when "unavailable"
      "#{sku} is #{actual.to_s.tr('_', ' ')} on our side."
    when "invalid_quantity"
      "#{sku}: quantity #{scrub_ids(actual.inspect)} is not a whole number of 1 or more. The line was dropped."
    when "invalid_price"
      "#{sku}: price #{scrub_ids(actual.inspect)} is not a valid amount. The line was dropped."
    when "currency_mismatch"
      "#{sku}: the customer's currency #{actual} differs from ours (#{expected})."
    when "unknown_catalog"
      "The order came from catalog #{actual.presence || 'unknown'}, not the configured catalog (#{expected})."
    when "malformed"
      "The order had no usable product lines."
    else
      "#{issue['code'].to_s.humanize}: expected #{scrub_ids(expected.inspect)}, got #{scrub_ids(actual.inspect)}."
    end
  end

  # The newest notification we queued for this order, for list pages.
  def latest_notification(order)
    order.messages.max_by(&:id)
  end

  def rejection_reason_label(stored)
    code, note = stored.to_s.split(": ", 2)
    [ Admin::OrdersController::REJECTION_REASONS.fetch(code, code.to_s.humanize), note ].compact.join(": ")
  end
end
