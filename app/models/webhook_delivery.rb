# One row per authenticated POST from Meta, stored before anything is
# interpreted. See docs/v2/DESIGN.md §2 and §3.
class WebhookDelivery < ApplicationRecord
  include StatusTransitions

  class ReplayError < StandardError; end
  class NotReplayable < ReplayError; end
  class SignatureRefused < ReplayError; end

  enum :status, {
    received: 0,
    processing: 1,
    processed: 2,
    partially_failed: 3,
    failed: 4,
    ignored: 5,
    unparseable: 6
  }

  ALLOWED_TRANSITIONS = {
    "received" => %w[processing],
    "failed" => %w[processing],
    "partially_failed" => %w[processing],
    "processed" => %w[processing],
    "processing" => %w[processed partially_failed failed ignored]
  }.freeze

  REPLAYABLE_STATUSES = %w[failed partially_failed processed].freeze

  validates :raw_body, :body_sha256, :received_at, presence: true

  def replayable?
    REPLAYABLE_STATUSES.include?(status)
  end

  # Operator replay (docs/v2/DESIGN.md §10): re-runs the stored body through the
  # same code that handled it the first time. Idempotency keys make items that
  # were already applied no-ops, so replaying is always safe.
  #
  # The stored signature is re-verified against the stored body with the
  # current app secret first, so a row edited after the fact (or stored under a
  # secret that has since been rotated away) is never fed back into the app.
  def replay!(by:)
    raise NotReplayable, "a #{status} delivery cannot be replayed" unless replayable?

    unless Whatsapp::Signature.valid?(raw_body, signature_header)
      AppLog.event("webhook.replay_refused", delivery_id: id, reason: "signature")
      raise SignatureRefused, "the stored body does not match its stored signature"
    end

    transaction do
      claimed = transition!(
        :processing,
        attempts: Arel.sql("attempts + 1"),
        replay_count: Arel.sql("replay_count + 1"),
        last_attempted_at: Time.current,
        last_replayed_at: Time.current,
        last_replayed_by: by
      )
      raise NotReplayable, "the delivery is no longer replayable (another worker moved it)" unless claimed

      ProcessWebhookDeliveryJob.perform_later(id, replay: true) || raise(ApplicationJob::EnqueueFailed, "ProcessWebhookDeliveryJob")
    end

    AppLog.event("webhook.replayed", delivery_id: id, by: by, replay_count: replay_count)
    self
  end
end
