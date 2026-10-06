module Ops
  # The 24-hour window: sends our guard blocked, and Meta's own "window closed"
  # refusals (131047). A refusal for a message our guard let through is a
  # disagreement between our clock logic and Meta's; refusals of operator
  # overrides are expected and counted separately.
  class WindowSection
    META_WINDOW_CLOSED = 131_047

    def initialize(period, real: false)
      @scope = Scopes.outbound(period, real: real)
    end

    def call
      refused = @scope.where(error_code: META_WINDOW_CLOSED)
      {
        blocked_window_closed: @scope.blocked.where(error_category: "window_closed").count,
        failures_131047: refused.count,
        disagreements: refused.where(guard_override_by: [ nil, "" ]).count
      }
    end
  end
end
