# Inbound and outbound WhatsApp messages share one table so a conversation is a
# single timeline. Outbound rows carry the delivery lifecycle; see
# docs/v2/DESIGN.md §3.
class Message < ApplicationRecord
  include StatusTransitions

  belongs_to :conversation
  belongs_to :order, optional: true
  belongs_to :webhook_delivery, optional: true

  enum :direction, { inbound: 0, outbound: 1 }

  # Inbound rows are always `received`; the rest describe an outbound message.
  enum :status, {
    received: 0,
    pending: 10,
    sending: 20,
    retry_scheduled: 25,
    accepted: 30,
    sent: 40,
    delivered: 50,
    read: 60,
    failed: 90,
    blocked: 91,
    unknown: 92
  }

  ALLOWED_TRANSITIONS = {
    "pending" => %w[sending blocked],
    "sending" => %w[accepted retry_scheduled failed unknown blocked],
    # A status webhook (found by our opaque id) can prove that a send we judged
    # retryable (5xx, 131000) was in fact processed: catch up to what Meta
    # reported instead of sending a second copy. See #catch_up_lifecycle!.
    "retry_scheduled" => %w[sending blocked sent delivered read failed],
    "accepted" => %w[sent delivered read failed],
    "sent" => %w[delivered read failed],
    "delivered" => %w[read],
    "unknown" => %w[sent delivered read failed],
    "failed" => %w[pending],
    "blocked" => %w[pending]
  }.freeze

  # Operator resend is only offered for failures a human can fix; resending
  # request_invalid or recipient_* would just fail the same way.
  RESENDABLE_ERROR_CATEGORIES = %w[auth_config account_config transient_exhausted unclassified].freeze

  # `blocked -> pending` additionally requires the 24h window to be open. That
  # check spans tables, so #requeue! enforces it (and #override_window_send!
  # deliberately sidesteps it), not the state machine.
  #
  # `retry_scheduled -> sending` (the retry's claim) additionally requires that
  # Meta has not already reported on the message: a wa_message_id or a sent /
  # delivered / read timestamp is proof an earlier attempt arrived, and sending
  # again would deliver a second copy. The condition sits in the claim's UPDATE
  # so a status webhook cannot slip in between a check and the claim.
  NO_DELIVERY_EVIDENCE = { wa_message_id: nil, sent_at: nil, delivered_at: nil, read_at: nil }.freeze

  TRANSITION_GUARDS = {
    %w[failed pending] => { error_category: RESENDABLE_ERROR_CATEGORIES },
    %w[retry_scheduled sending] => NO_DELIVERY_EVIDENCE
  }.freeze

  # Delivery lifecycle as reported by Meta, in forward order, and the column
  # that records when each step happened.
  LIFECYCLE = %w[accepted sent delivered read].freeze
  LIFECYCLE_COLUMNS = {
    "accepted" => "accepted_at",
    "sent" => "sent_at",
    "delivered" => "delivered_at",
    "read" => "read_at"
  }.freeze

  validates :message_type, presence: true

  scope :chronological, -> { order(:created_at, :id) }

  # Accepted by Meta but no delivery receipt for a while: a query, not a state.
  scope :undelivered, -> {
    outbound.where(status: %w[accepted sent]).where(delivered_at: nil).where(accepted_at: ...10.minutes.ago)
  }

  # Leaving `sending` is the moment the stamped timestamps become meaningful:
  # statuses that arrived while the send was still in flight could only leave
  # their timestamp behind. After the send settles (accepted, or unknown after
  # a read timeout or a stall) the state catches up to the furthest step Meta
  # has reported, so proof of delivery is never stranded behind `unknown`.
  #
  # Entering `unknown` also stamps `unknown_at` (once per entry), so the report
  # can say how many unknowns were later resolved.
  def transition!(to, **attrs)
    attrs = { unknown_at: Time.current }.merge(attrs) if to.to_s == "unknown"
    super(to, **attrs).tap { |moved| catch_up_lifecycle! if moved && %w[accepted unknown].include?(to.to_s) }
  end

  # Records a lifecycle event (accepted/sent/delivered/read) and moves the state
  # forward if, and only if, that is progress. Returns true when anything
  # changed, false when the event was already known.
  #
  # Each timestamp is written at most once, even when the state cannot advance:
  # a `delivered` that arrives after `read` still fills delivered_at.
  # Events seen while `sending` (the HTTP response has not been recorded yet) only
  # leave their timestamp; the sender's own `accepted` event then catches the
  # state up to the furthest step already reported.
  def apply_lifecycle!(event, at:)
    event = event.to_s
    column = LIFECYCLE_COLUMNS.fetch(event)

    stamped = self.class.where(id: id, column => nil).update_all(column => at, updated_at: Time.current) == 1
    reload
    advanced = advance_lifecycle!(event)

    stamped || advanced
  end

  # A failure report from Meta. Returns :applied, :duplicate (already failed),
  # :anomaly (it is already delivered/read, so the report contradicts what we
  # know and changes nothing) or :ignored (a state a webhook may not move).
  def apply_failure!(at:, code: nil, title: nil, details: nil)
    return :duplicate if failed?
    return :anomaly if delivered? || read?

    moved = transition!(
      :failed,
      failed_at: at,
      error_code: code,
      error_title: title,
      error_details: details,
      error_category: Whatsapp::ErrorClassifier.category_for(code: code)
    )
    moved ? :applied : (failed? ? :duplicate : :ignored)
  end

  # What an operator resend/requeue wipes: the failure, and any lifecycle
  # evidence from the attempt that failed. Attempts restart so the retry
  # schedule starts over.
  FRESH_START = {
    attempts: 0, next_attempt_at: nil, failed_at: nil, blocked_at: nil,
    error_code: nil, error_category: nil, error_title: nil, error_details: nil,
    accepted_at: nil, sent_at: nil, delivered_at: nil, read_at: nil
  }.freeze

  # Ops::Purge removed this message's text, payload and Meta id; there is nothing
  # left to send, so the operator actions refuse it.
  PURGED_REASON = "purged".freeze

  def purged? = purged_at.present?

  # Operator actions (docs/v2/DESIGN.md §3). They only write the row and enqueue
  # the job; they never call Meta. Each returns an ActionResult.

  # failed -> pending, for categories a human can fix (config, exhausted retries).
  def resend!(by:)
    require_actor!(by)
    return ActionResult.refused(PURGED_REASON) if purged?
    return ActionResult.refused("only a failed message can be resent (it is #{status})") unless failed?
    unless RESENDABLE_ERROR_CATEGORIES.include?(error_category)
      return ActionResult.refused("a #{error_category || 'uncategorised'} failure cannot be resent: it would fail the same way")
    end

    previous = error_category
    start_over!(:pending, "message.resend", by: by, previous_category: previous, wa_message_id: nil)
  end

  # blocked -> pending, only while the 24h window is open now.
  def requeue!(by:)
    require_actor!(by)
    return ActionResult.refused(PURGED_REASON) if purged?
    return ActionResult.refused("only a blocked message can be requeued (it is #{status})") unless blocked?
    return ActionResult.refused("the 24-hour window is closed; wait for the customer to write again") unless conversation.reload.window_open?

    start_over!(:pending, "message.requeue", by: by, guard_override_by: nil)
  end

  # Experiment, admin only: blocked -> pending that the job will send even though
  # the window is closed. Meta will most likely refuse (131047); the point is to
  # find out. Logged loudly here and again when the job honours it.
  def override_window_send!(by:)
    require_actor!(by)
    return ActionResult.refused(PURGED_REASON) if purged?
    return ActionResult.refused("only a blocked message can be overridden (it is #{status})") unless blocked?

    AppLog.warn("window.override_requested", message_id: id, by: by)
    start_over!(:pending, "message.override_window_send", by: by, guard_override_by: by)
  end

  # Resends every failed message of one fixable category (e.g. after fixing the
  # token). Returns an ActionResult whose count is how many were queued.
  def self.resend_failed!(category:, by:)
    return ActionResult.refused("#{category.inspect} is not a resendable category") unless RESENDABLE_ERROR_CATEGORIES.include?(category.to_s)

    count = outbound.failed.where(error_category: category.to_s).find_each.count { |message| message.resend!(by: by).ok? }
    AppLog.event("message.resend_bulk", category: category, by: by, count: count)
    ActionResult.ok(count: count)
  end

  # Meta says the 24h window was closed (131047) for a message we sent because
  # our own guard thought it open: a diagnostic for the margin and clock logic,
  # not an error. Skipped when an operator deliberately overrode the guard.
  def log_window_disagreement(source:)
    return if guard_override_by.present?

    AppLog.warn("window_disagreement", message_id: id, conversation_id: conversation_id, source: source,
                                       last_inbound_at: conversation.last_inbound_at&.iso8601)
  end

  # True when Meta has already told us something about this message: its id, or
  # a sent / delivered / read timestamp.
  def delivery_evidence?
    wa_message_id.present? || %w[sent delivered read].any? { |step| self[LIFECYCLE_COLUMNS.fetch(step)] }
  end

  # Moves forward to the furthest lifecycle step that has a timestamp, if that is
  # progress. Never while `sending` (the sender has not recorded its outcome yet)
  # and never backwards. Leaving `retry_scheduled` this way also drops the retry
  # bookkeeping: the attempt that "failed" evidently arrived. Returns true when
  # the state moved.
  def catch_up_lifecycle!
    return false if sending?

    target = LIFECYCLE.reverse.find { |step| self[LIFECYCLE_COLUMNS.fetch(step)] }
    return false unless target && lifecycle_rank(target) > lifecycle_rank(status)
    return transition!(target, next_attempt_at: nil, error_code: nil, error_category: nil, error_title: nil, error_details: nil) if retry_scheduled?

    transition!(target)
  end

  private

  def require_actor!(by)
    raise ArgumentError, "by: is required" if by.blank?
  end

  # One transaction: move to `to`, wipe the previous attempt, enqueue the job.
  def start_over!(to, event, by:, previous_category: nil, **extra)
    moved = self.class.transaction do
      transition!(to, **FRESH_START, **extra).tap do |ok|
        (SendMessageJob.perform_later(id) || raise(ApplicationJob::EnqueueFailed, "SendMessageJob")) if ok
      end
    end
    return ActionResult.refused("the message changed state before the action could apply; reload and try again") unless moved

    AppLog.event(event, message_id: id, by: by, previous_category: previous_category)
    ActionResult.ok
  end

  def advance_lifecycle!(event)
    moved = false
    moved = transition!(:accepted) if sending? && event == "accepted"

    catch_up_lifecycle! || moved
  end

  def lifecycle_rank(step)
    LIFECYCLE.index(step.to_s)&.succ || 0
  end
end
