# Deliberate, labeled failures for the operating-period scenarios
# (docs/operating/PROTOCOL.md 4, 6, 7).
#
# Two gates, both required:
#
#   1. The environment allows it at all: `Rails.env.local?`, or production with
#      FAULT_INJECTION_ALLOWED=1 (a deploy-time decision; see config/deploy.yml).
#   2. A toggle is switched on. The toggles live in the database (OpsSetting,
#      switched from the Health page, recording who did it) so a scenario run
#      needs no redeploy: a redeploy restarts Puma and the in-process queue and
#      would turn in-flight sends into `unknown`. In development and test the
#      FAULT_INJECT environment variable (comma-separated) is read as an
#      additional source, which keeps local tooling and specs simple. In
#      production FAULT_INJECT must not be set at all (ProductionConfigCheck).
#
# A toggle fires for EVERY matching event while it is on, for every participant:
# switch it on, run one scenario, switch it off. Every firing is labeled: an
# `AppLog.warn("fault.injected")` event, and the affected row carries the label
# (INJECTED_PREFIX in message error details, "injected:<kind>" in the delivery's
# item outcome and in the append-only injected_faults column), so injected
# evidence is never mistaken for real.
module FaultInjection
  class Injected < StandardError; end
  class NotAllowed < StandardError; end

  KINDS = %w[processing:order send:5xx send:read_timeout_after_send].freeze
  INJECTED_PREFIX = "[injected]".freeze

  # The toggles that are set, whether or not they are known or allowed:
  # stored ones, plus FAULT_INJECT in development and test.
  def self.requested(env = ENV)
    (stored + (Rails.env.local? ? parse(env["FAULT_INJECT"]) : [])).uniq
  end

  def self.allowed?(env = ENV)
    Rails.env.local? || (Rails.env.production? && env["FAULT_INJECTION_ALLOWED"] == "1")
  end

  # Toggles that will actually fire.
  def self.active(env = ENV)
    allowed?(env) ? requested(env) & KINDS : []
  end

  # Names that are set but will not fire: not allowed here, or not a known toggle.
  def self.ignored(env = ENV)
    requested(env) - active(env)
  end

  def self.active?(kind, env = ENV)
    active(env).include?(kind)
  end

  # What the operator last stored: { kinds:, by:, at: }.
  def self.stored_state
    setting = OpsSetting.current
    { kinds: setting.fault_inject, by: setting.updated_by, at: setting.updated_at }
  end

  # Replaces the stored toggles (the admin switch). Raises NotAllowed where
  # injection is not allowed and ArgumentError for an unknown kind.
  def self.set!(kinds, by:, env: ENV)
    raise NotAllowed, "fault injection is not allowed in this environment" unless allowed?(env)
    raise ArgumentError, "by: is required" if by.blank?

    kinds = Array(kinds).map(&:to_s).reject(&:empty?).uniq
    unknown = kinds - KINDS
    raise ArgumentError, "unknown fault kind: #{unknown.join(', ')}" if unknown.any?

    previous = stored
    OpsSetting.current.update!(fault_inject: kinds, updated_by: by, updated_at: Time.current)
    AppLog.warn("fault.toggled", by: by, kinds: kinds.join(","), previous: previous.join(","))
    kinds
  end

  def self.stored
    OpsSetting.current.fault_inject
  end
  private_class_method :stored

  def self.parse(text)
    text.to_s.split(",").map(&:strip).reject(&:empty?).uniq
  end
  private_class_method :parse

  # Logs one firing and appends it to the affected row's injected_faults, a
  # column nothing ever clears (a successful retry wipes error details and a
  # replay replaces the outcome, but the evidence that a fault was injected must
  # survive both). Returns the label to store on the affected row.
  def self.fire(kind, message_id: nil, delivery_id: nil, **fields)
    AppLog.warn("fault.injected", kind: kind, message_id: message_id, delivery_id: delivery_id, **fields.compact)
    label = "injected:#{kind}"
    append = [ "injected_faults = array_append(injected_faults, ?)", label ]
    Message.where(id: message_id).update_all(append) if message_id
    WebhookDelivery.where(id: delivery_id).update_all(append) if delivery_id
    label
  end
end
