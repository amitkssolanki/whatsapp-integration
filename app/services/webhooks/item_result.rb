module Webhooks
  # What happened to one message or status inside a delivery. Stored in
  # webhook_deliveries.outcome. `result` is one of:
  #   applied    - changed state
  #   duplicate  - already applied earlier (idempotent no-op)
  #   orphan     - a status for a message we do not know (a replay may apply it later)
  #   anomaly    - contradicts what we know (e.g. failed after delivered); nothing changed
  #   ignored    - understood but deliberately not handled
  #   error      - raised; the item's transaction was rolled back
  ItemResult = Data.define(:kind, :ref, :result, :detail) do
    def self.for(kind, ref, result, detail = nil)
      new(kind: kind, ref: ref, result: result, detail: detail)
    end

    def to_outcome
      { "kind" => kind, "ref" => ref, "result" => result, "detail" => detail }
    end
  end
end
