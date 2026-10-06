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

  # The bodies hold phone numbers, names and message text, and can be megabytes.
  # Anything that only displays deliveries (the admin pages, Health) reads
  # `without_bodies`; a record loaded that way raises MissingAttributeError if
  # code reaches for a body by accident.
  BODY_COLUMNS = %w[raw_body raw_body_base64].freeze
  scope :without_bodies, -> { select(column_names - BODY_COLUMNS) }

  validates :body_sha256, :received_at, presence: true
  # An empty (or all-NUL, once scrubbed) body is a legitimate thing to have
  # received and signed; only a missing one is a bug.
  validates :raw_body, exclusion: { in: [ nil ], message: :blank }

  # The exact bytes Meta sent, which the signature covers. Almost always that is
  # raw_body; bodies PostgreSQL text cannot hold (invalid UTF-8, NUL) keep a
  # scrubbed copy in raw_body for display and the real bytes, base64 encoded,
  # in raw_body_base64. Returns a new, binary string. Raises ArgumentError when
  # the stored base64 is corrupt.
  def raw_bytes
    raw_body_base64.present? ? Base64.strict_decode64(raw_body_base64) : raw_body.to_s.b
  end

  # The stored signature checked against the stored exact bytes and the
  # current app secret.
  def stored_signature_valid?
    Whatsapp::Signature.valid?(raw_bytes, signature_header)
  rescue ArgumentError
    false
  end

  # The raw body was removed by Ops::Purge; the row keeps only its aggregates.
  def purged?
    purged_at.present?
  end

  def replayable?
    REPLAYABLE_STATUSES.include?(status) && !purged?
  end

  # Operator replay (docs/v2/DESIGN.md §10): re-runs the stored body through the
  # same code that handled it the first time. Idempotency keys make items that
  # were already applied no-ops, so replaying is always safe.
  #
  # The stored signature is re-verified against the stored body with the
  # current app secret first, so a row edited after the fact (or stored under a
  # secret that has since been rotated away) is never fed back into the app.
  def replay!(by:)
    raise NotReplayable, "the raw body was purged on #{purged_at.to_date.iso8601}, so this delivery can no longer be replayed" if purged?
    raise NotReplayable, "a #{status} delivery cannot be replayed" unless replayable?

    unless stored_signature_valid?
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
