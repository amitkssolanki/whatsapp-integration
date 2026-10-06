# Keep specs hermetic: a developer's FAULT_INJECT must never change a result,
# and a spec that sets one must not leak it into the next.
module FaultInjectionHelpers
  def inject_faults(*kinds)
    ENV["FAULT_INJECT"] = kinds.join(",")
  end
end

RSpec.configure do |config|
  config.include FaultInjectionHelpers

  config.around do |example|
    saved = ENV.to_h.slice("FAULT_INJECT", "FAULT_INJECTION_ALLOWED")
    ENV.delete("FAULT_INJECT")
    ENV.delete("FAULT_INJECTION_ALLOWED")
    example.run
  ensure
    ENV.delete("FAULT_INJECT")
    ENV.delete("FAULT_INJECTION_ALLOWED")
    saved.each { |key, value| ENV[key] = value }
  end
end
