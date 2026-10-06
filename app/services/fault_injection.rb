# Deliberate, labeled failures for the operating-period scenarios
# (docs/operating/PROTOCOL.md 4, 6, 7).
#
#   FAULT_INJECT=processing:order,send:5xx bin/rails server
#
# Toggles are read from the environment on every check, so they can be
# switched off without code changes. They are only honoured in development and
# test, or in production when FAULT_INJECTION_ALLOWED=1 (and production refuses
# to boot with FAULT_INJECT set but not allowed: ProductionConfigCheck).
#
# A toggle fires for every matching event while it is set. Every firing is
# labeled: an `AppLog.warn("fault.injected")` event, and the affected row carries
# the label (INJECTED_PREFIX in message error details, "injected:<kind>" in the
# delivery's item outcome), so injected evidence is never mistaken for real.
module FaultInjection
  class Injected < StandardError; end

  KINDS = %w[processing:order send:5xx send:read_timeout_after_send].freeze
  INJECTED_PREFIX = "[injected]".freeze

  # The toggles that are set, whether or not they are known or allowed.
  def self.requested(env = ENV)
    env["FAULT_INJECT"].to_s.split(",").map(&:strip).reject(&:empty?).uniq
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

  # Logs one firing. Returns the label to store on the affected row.
  def self.fire(kind, **fields)
    AppLog.warn("fault.injected", kind: kind, **fields)
    "injected:#{kind}"
  end
end
