# Presentation helpers for the operator UI: refresh, times, and how a message's
# delivery state reads at a glance (docs/v2/DESIGN.md §3, §8).
module AdminHelper
  REFRESH_SECONDS = 5

  # state => [tick, css tone, label]. The tick is decoration; the label always
  # carries the meaning.
  MESSAGE_STATES = {
    "received" => [ "←", "neutral", "received" ],
    "pending" => [ "⏳", "pending", "pending" ],
    "sending" => [ "⏳", "pending", "sending" ],
    "retry_scheduled" => [ "↻", "warn", "retry scheduled" ],
    "accepted" => [ "✓", "accepted", "accepted by Meta" ],
    "sent" => [ "✓", "sent", "sent" ],
    "delivered" => [ "✓✓", "sent", "delivered" ],
    "read" => [ "✓✓", "read", "read" ],
    "failed" => [ "✕", "bad", "failed" ],
    "blocked" => [ "⛔", "bad", "blocked: 24h window" ],
    "unknown" => [ "?", "warn", "outcome unknown" ]
  }.freeze

  # Pages whose forms are not being filled call this once; the layout then emits
  # the 5 second refresh. ?live=0 turns it off.
  def live_refresh
    return if live_refresh_paused?

    @live_refresh = true
    content_for :head, tag.meta("http-equiv": "refresh", content: REFRESH_SECONDS)
  end

  def live_refresh?
    @live_refresh == true
  end

  def live_refresh_paused?
    params[:live].to_s == "0"
  end

  def admin_time(time, seconds: false)
    return "—" if time.blank?

    time.strftime(seconds ? "%b %-d, %H:%M:%S" : "%b %-d, %H:%M")
  end

  # A short span for countdowns ("23h 5m left"): 4500 seconds -> "1h 15m"; under a minute -> "<1m".
  def duration_words(seconds)
    minutes = (seconds.to_f / 60).floor
    return "<1m" if minutes < 1

    hours, minutes = minutes.divmod(60)
    hours.positive? ? "#{hours}h #{minutes}m" : "#{minutes}m"
  end

  # "about 2 months ago", with the exact moment (and year) in the title attribute.
  # Long gaps read as months, not as "1406h 14m".
  def ago(time, now: Time.current)
    return "—" if time.blank?

    tag.span("#{distance_of_time_in_words(time, now)} ago", title: time.strftime("%Y-%m-%d %H:%M:%S %Z"))
  end

  def badge(text, tone = "neutral")
    tag.span(text, class: "badge badge-#{tone}")
  end

  # The message's delivery state: tick, label, and whatever else an operator needs
  # to understand it (the error, the next retry).
  def message_state(message)
    tick, tone, label = MESSAGE_STATES.fetch(message.status, [ "?", "warn", message.status.to_s.humanize.downcase ])
    parts = [ tag.span(tick, class: "tick", "aria-hidden": "true"), " ", tag.span(label, class: "state-label") ]
    detail = message_state_detail(message)
    parts << tag.span(" · #{detail}", class: "state-detail") if detail
    tag.span(safe_join(parts), class: "state state-#{tone}")
  end

  def message_state_detail(message)
    case message.status
    when "failed"
      [ message.error_category, scrub_ids(message.error_title).presence, ("code #{message.error_code}" if message.error_code) ].compact.join(" · ").presence
    when "retry_scheduled"
      "next attempt #{admin_time(message.next_attempt_at, seconds: true)} (attempt #{message.attempts})"
    when "sending", "pending"
      "attempt #{message.attempts}" if message.attempts.to_i.positive?
    end
  end

  # Compact badge for list pages.
  def window_badge(conversation, now: Time.current)
    if conversation.window_open?(at: now)
      badge("window open · #{duration_words(conversation.window_closes_at - now)} left", "ok")
    elsif conversation.last_inbound_at.nil?
      badge("window closed · customer never wrote", "bad")
    else
      badge("window closed", "bad")
    end
  end

  # The full sentence for a conversation header.
  def window_header(conversation, now: Time.current)
    closes_at = conversation.window_closes_at
    if conversation.window_open?(at: now)
      "Window open until #{closes_at.strftime('%H:%M')} (#{duration_words(closes_at - now)} left)"
    elsif closes_at
      "Window closed at #{closes_at.strftime('%b %-d, %H:%M')}"
    else
      "Window closed: the customer has never written"
    end
  end

  def nav_link(label, path, *controllers)
    current = controllers.include?(controller_path)
    link_to label, path, "aria-current": (current ? "page" : nil), class: ("current" if current)
  end
end
