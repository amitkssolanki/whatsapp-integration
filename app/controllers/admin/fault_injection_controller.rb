module Admin
  # The runtime switch for the scenario fault toggles (FaultInjection). Only
  # works where injection is allowed (local, or production with
  # FAULT_INJECTION_ALLOWED=1); switching a toggle ON needs the confirm box.
  # Switching everything off never does.
  class FaultInjectionController < BaseController
    def update
      kinds = Array(params[:kinds]).map(&:to_s) & FaultInjection::KINDS
      return refuse("Fault injection is not allowed in this environment.") unless FaultInjection.allowed?

      adding = kinds - FaultInjection.stored_state[:kinds]
      return refuse("Tick the box to confirm: while a toggle is on, every matching event fails for every participant.") if adding.any? && params[:confirm] != "1"

      FaultInjection.set!(kinds, by: current_operator)
      redirect_to admin_health_path, notice: kinds.any? ? "Fault injection ON: #{kinds.join(', ')}. Switch it off when the scenario is done." : "Fault injection is OFF."
    end

    private

    def refuse(reason)
      redirect_to admin_health_path, alert: "Not done: #{reason}"
    end
  end
end
